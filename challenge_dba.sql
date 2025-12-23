
-- ---------------------------------------------------------------------------
-- Challenge DBA — Script SQL Completo (PostgreSQL)
-- Autor: Michel Inocêncio de Sá (adaptado pelo M365 Copilot)
-- Data: 2025-12-23
-- ---------------------------------------------------------------------------
-- Este script implementa:
--  - Modelo multi-tenant com tabelas: tenant, person, institution, course, enrollment
--  - Chaves primárias e estrangeiras
--  - Regra de unicidade (tenant/person/institution com suporte a NULL)
--  - Exclusão lógica via deleted_at
--  - Índices (incluindo parciais) e GIN para JSONB
--  - Particionamento de enrollment por faixa de data (mensal)
--  - View de registros ativos e opção de RLS
--  - Ajustes de autovacuum e fillfactor
--  - Funções utilitárias para criação de partições
--
-- Observações/Assunções:
--  * Este schema é genérico; ajuste nomes de colunas conforme seu domínio real.
--  * O script assume PostgreSQL >= 13 (particionamento, INCLUDE, GIN JSONB).
--  * Evite rodar CREATE INDEX CONCURRENTLY dentro de transações; aqui usamos sem CONCURRENTLY.
-- ---------------------------------------------------------------------------

-- (Opcional) Criar extensão para estatísticas de consultas e buscas textuais
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
-- 1) Tabelas base
-- ---------------------------------------------------------------------------

-- Tabela de tenants
CREATE TABLE IF NOT EXISTS tenant (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT        NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tabela de pessoas (metadados flexíveis via JSONB)
CREATE TABLE IF NOT EXISTS person (
  id          BIGSERIAL PRIMARY KEY,
  full_name   TEXT        NOT NULL,
  birth_date  DATE,
  metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
  deleted_at  TIMESTAMPTZ NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tabela de instituições (escopo por tenant)
CREATE TABLE IF NOT EXISTS institution (
  id          BIGSERIAL PRIMARY KEY,
  tenant_id   BIGINT      NOT NULL,
  name        TEXT        NOT NULL,
  code        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT institution_tenant_fk FOREIGN KEY (tenant_id)
    REFERENCES tenant (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT institution_unique_name_per_tenant UNIQUE (tenant_id, name)
);

-- Tabela de cursos (associados a tenant e, opcionalmente, a uma instituição)
CREATE TABLE IF NOT EXISTS course (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      BIGINT      NOT NULL,
  institution_id BIGINT      NULL,
  name           TEXT        NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT course_tenant_fk FOREIGN KEY (tenant_id)
    REFERENCES tenant (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT course_institution_fk FOREIGN KEY (institution_id)
    REFERENCES institution (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT course_unique_name_per_tenant UNIQUE (tenant_id, name)
);

-- ---------------------------------------------------------------------------
-- 2) Tabela de matrículas (enrollment) — Particionada por data
-- ---------------------------------------------------------------------------

-- A tabela pai é particionada por RANGE(enrollment_date)
CREATE TABLE IF NOT EXISTS enrollment (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      BIGINT      NOT NULL,
  institution_id BIGINT      NULL,
  person_id      BIGINT      NOT NULL,
  course_id      BIGINT      NOT NULL,
  enrollment_date DATE       NOT NULL,
  status         TEXT        NOT NULL CHECK (status IN ('pending','active','completed','cancelled')),
  deleted_at     TIMESTAMPTZ NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- FKs que reforçam integridade multi-tenant
  CONSTRAINT enrollment_tenant_fk FOREIGN KEY (tenant_id)
    REFERENCES tenant (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT enrollment_person_fk FOREIGN KEY (person_id)
    REFERENCES person (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT enrollment_institution_fk FOREIGN KEY (institution_id)
    REFERENCES institution (id) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT enrollment_course_fk FOREIGN KEY (course_id)
    REFERENCES course (id) ON UPDATE CASCADE ON DELETE RESTRICT
) PARTITION BY RANGE (enrollment_date);

-- Regra de unicidade: para cada (tenant_id, person_id), a combinação com institution_id não deve duplicar
-- Abordagem 1: COALESCE, compatível com versões antigas e aceita institution_id NULL
-- Observação: para tabelas particionadas, índices únicos devem ser criados na tabela pai
CREATE UNIQUE INDEX IF NOT EXISTS uniq_enroll_tenant_person_inst
  ON ONLY enrollment (tenant_id, person_id, COALESCE(institution_id, -1));

-- Alternativa (comentada): índices parciais com INCLUDE (PG >= 15) — crie por partição
-- CREATE UNIQUE INDEX uniq_enroll_tenant_person_inst_part ON enrollment
--   (tenant_id, person_id) INCLUDE (institution_id) WHERE institution_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3) Índices (na tabela pai e serão replicados por partição conforme necessidade)
-- ---------------------------------------------------------------------------

-- Índice composto para filtros frequentes (tenant/institution), ordenação por data e status
CREATE INDEX IF NOT EXISTS idx_enroll_tenant_inst_date_status
  ON ONLY enrollment (tenant_id, institution_id, enrollment_date DESC, status);

-- Índice para acesso rápido por pessoa
CREATE INDEX IF NOT EXISTS idx_enroll_person
  ON ONLY enrollment (person_id);

-- Índice parcial para registros ativos (soft delete)
CREATE INDEX IF NOT EXISTS idx_enroll_active
  ON ONLY enrollment (tenant_id, institution_id, person_id)
  WHERE deleted_at IS NULL;

-- Índices auxiliares em course/institution
CREATE INDEX IF NOT EXISTS idx_course_tenant_inst
  ON course (tenant_id, institution_id);

CREATE INDEX IF NOT EXISTS idx_institution_tenant
  ON institution (tenant_id);

-- Índice GIN para consultas em JSONB (person.metadata)
CREATE INDEX IF NOT EXISTS idx_person_metadata_jsonb
  ON person USING GIN (metadata jsonb_path_ops);

-- ---------------------------------------------------------------------------
-- 4) View com soft delete aplicado
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW enrollment_active AS
SELECT *
FROM enrollment
WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 5) (Opcional) Row Level Security para reforçar leitura de registros ativos
-- ---------------------------------------------------------------------------
-- ATENÇÃO: RLS depende de roles e do contexto da aplicação; habilite se for adequado.
-- ALTER TABLE enrollment ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY read_active_enrollments ON enrollment
--   FOR SELECT USING (deleted_at IS NULL);

-- ---------------------------------------------------------------------------
-- 6) Partições mensais e funções utilitárias
-- ---------------------------------------------------------------------------

-- Função para criar uma partição mensal com índices locais
CREATE OR REPLACE FUNCTION create_enrollment_partition(start_date DATE)
RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  end_date   DATE;
  part_name  TEXT;
BEGIN
  end_date := (date_trunc('month', start_date) + INTERVAL '1 month')::date;
  part_name := format('enrollment_%s', to_char(start_date, 'YYYY_MM'));

  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS %I PARTITION OF enrollment FOR VALUES FROM (%L) TO (%L);',
    part_name, start_date, end_date
  );

  -- Índices locais (replicam a estratégia da tabela pai)
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS %I_idx_tenant_inst_date_status ON %I (tenant_id, institution_id, enrollment_date DESC, status);',
    part_name, part_name
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS %I_idx_enroll_person ON %I (person_id);',
    part_name, part_name
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS %I_idx_enroll_active ON %I (tenant_id, institution_id, person_id) WHERE deleted_at IS NULL;',
    part_name, part_name
  );
END;
$$;

-- Procedure para criar N partições a partir de uma data (mês)
CREATE OR REPLACE PROCEDURE create_enrollment_partitions(from_month DATE, months INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
  i INTEGER;
  d DATE;
BEGIN
  IF months < 1 THEN
    RAISE EXCEPTION 'months deve ser >= 1';
  END IF;

  FOR i IN 0..months-1 LOOP
    d := (date_trunc('month', from_month) + (i || ' months')::interval)::date;
    PERFORM create_enrollment_partition(d);
  END LOOP;
END;
$$;

-- Crie partições de exemplo (ajuste conforme necessidade)
-- CALL create_enrollment_partitions(date '2025-12-01', 3);  -- 2025-12, 2026-01, 2026-02

-- ---------------------------------------------------------------------------
-- 7) Ajustes de manutenção: autovacuum e fillfactor
-- ---------------------------------------------------------------------------

-- Autovacuum mais agressivo em enrollment (alta taxa de escrita)
ALTER TABLE enrollment SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_analyze_threshold = 500
);

-- Fillfactor em tabelas com atualizações (ex.: person)
ALTER TABLE person SET (fillfactor = 80);

-- ---------------------------------------------------------------------------
-- 8) Exemplos de consultas de negócio (para referência)
-- ---------------------------------------------------------------------------

-- Contagem de matrículas por curso em um período
-- Ajuste parâmetros conforme necessidade
-- SELECT c.id AS course_id,
--        c.name,
--        COUNT(*) AS num_enrollments
-- FROM enrollment e
-- JOIN course c
--   ON e.tenant_id = c.tenant_id
--  AND e.institution_id = c.institution_id
--  AND e.course_id = c.id
-- WHERE e.tenant_id = $1
--   AND e.institution_id = $2
--   AND e.deleted_at IS NULL
--   AND e.enrollment_date BETWEEN $3 AND $4
-- GROUP BY c.id, c.name;

-- Listagem de alunos de um curso (com paginação)
-- SELECT p.id, p.full_name, p.birth_date, p.metadata
-- FROM enrollment e
-- JOIN person p ON p.id = e.person_id
-- WHERE e.tenant_id = $1
--   AND e.institution_id = $2
--   AND e.course_id = $3
--   AND e.deleted_at IS NULL
-- ORDER BY p.full_name
-- LIMIT $4 OFFSET $5;

-- ---------------------------------------------------------------------------
-- Fim do script
-- ---------------------------------------------------------------------------
