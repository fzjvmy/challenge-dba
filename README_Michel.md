# 🏗️ PostgreSQL Multi-Tenant Challenge

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE) [![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-blue.svg)]() [![Status](https://img.shields.io/badge/status-stable-success.svg)]()

## 📌 Sobre o Projeto
Este repositório contém um desafio de arquitetura para um banco **multi-tenant** utilizando **PostgreSQL**, com foco em:
- Integridade referencial
- Índices otimizados
- Exclusão lógica
- Particionamento
- Consultas eficientes
- Boas práticas de manutenção, segurança e alta disponibilidade

---

## 🚀 Como Usar

### Pré-requisitos
- PostgreSQL 13 ou superior
- Acesso ao `psql` ou ferramenta equivalente

### Instalação
```bash
# Clone o repositório
git clone https://github.com/grupo-a/challenge-dba.git
cd challenge-dba

# Crie o banco e aplique os scripts
psql -U seu_usuario -d seu_banco -f scripts/schema.sql
```

### Estrutura do Repositório
| Pasta / Arquivo      | Descrição |
|----------------------|-----------|
| `scripts/`           | Scripts SQL para criação de tabelas, índices e partições |
| `README.md`          | Documentação completa do projeto |

---

## 📖 Documentação Técnica
# Documentação de Arquitetura e Boas Práticas — Banco Multi-Tenant (PostgreSQL)

## Sumário
1. [Objetivos e Contexto](#objetivos-e-contexto)  
2. [Modelo de Dados e Integridade](#modelo-de-dados-e-integridade)  
   2.1 [Chaves Primárias](#chaves-primárias)  
   2.2 [Chaves Estrangeiras](#chaves-estrangeiras)  
   2.3 [Unicidade entre Tenant / Institution / Person](#unicidade-entre-tenant--institution--person)  
3. [Exclusão Lógica (Soft Delete)](#exclusão-lógica-soft-delete)  
4. [Índices e Performance](#índices-e-performance)  
   4.1 [Critérios de Criação](#critérios-de-criação)  
   4.2 [Índices Parciais e Include](#índices-parciais-e-include)  
   4.3 [JSONB e GIN](#jsonb-e-gin)  
5. [Particionamento de Dados](#particionamento-de-dados)  
   5.1 [Estratégia de Particionamento](#estratégia-de-particionamento)  
   5.2 [Operações e Manutenção por Partição](#operações-e-manutenção-por-partição)  
6. [Consultas-Alvo (Queries de Negócio)](#consultas-alvo-queries-de-negócio)  
7. [Manutenção, Autovacuum e Bloat](#manutenção-autovacuum-e-bloat)  
8. [Configuração da Instância (Tuning)](#configuração-da-instância-tuning)  
9. [Alta Disponibilidade e Backups](#alta-disponibilidade-e-backups)  
10. [Segurança e Governança](#segurança-e-governança)  
11. [Observabilidade e Monitoramento](#observabilidade-e-monitoramento)  
12. [Migrações de Esquema e Operações Seguras](#migrações-de-esquema-e-operações-seguras)  
13. [Riscos, Trade-offs e Decisões](#riscos-trade-offs-e-decisões)  
14. [Checklist de Execução](#checklist-de-execução)

---

## 1) Objetivos e Contexto
**Desafio**: Base multi-tenant com tabelas `tenant`, `person`, `institution`, `course` e `enrollment`. Requisitos incluem integridade referencial, unicidade por tenant/institution/person, exclusão lógica, consultas eficientes (incluindo JSONB), particionamento e boas práticas operacionais.

**Objetivo desta documentação**: Justificar tecnicamente cada escolha de arquitetura e operação, garantindo **consistência dos dados**, **performance sustentada**, **facilidade de manutenção**, **segurança** e **escalabilidade**.

---

## 2) Modelo de Dados e Integridade

### 2.1 Chaves Primárias
**Escolha**: Definir chaves primárias em todas as tabelas (`id`) como base de identidade.

**Por quê**:
- Garante unicidade e referência estável entre entidades.
- Facilita replicação, particionamento e manutenção.
- É pré-requisito para índices eficientes e para FKs.

**Impacto**:
- Melhora de performance em `JOIN`s e lookups.
- Simplifica estruturas de índices (PK → índice BTREE implícito).

---

### 2.2 Chaves Estrangeiras
**Escolha**: FKs de `institution` → `tenant`, `course` → (`tenant`, `institution`), `enrollment` → (`tenant`, `person`, `institution`).

**Por quê**:
- Assegura **integridade referencial**: não há matrículas órfãs, cursos sem instituição/tenant, etc.
- Captura regras de negócio de multi-tenancy: dados do tenant não “vazam” ou se associam indevidamente a outro.

**Impacto**:
- Previne inconsistências lógicas (erros invisíveis).
- Pode aumentar custo de `INSERT/DELETE`, porém é compensado pelo benefício de integridade e auditoria.

**Boas práticas**:
- FKs **simétricas** com colunas que participam dos **JOINs** reais do negócio (incluindo `tenant_id`).
- `ON DELETE` decidido conforme regra (geralmente `RESTRICT`/`NO ACTION`; evitar cascata em multi-tenant se exclusão lógica for usada).

---

### 2.3 Unicidade entre Tenant / Institution / Person
**Escolha**: Índice único garantindo que, para cada `(tenant_id, person_id)`, a combinação com `institution_id` não gere duplicidade indesejada — contemplando casos com `institution_id` nulo.

**Por quê**:
- Encapsula a regra de negócio de **uma matrícula única por pessoa dentro de um tenant**, podendo ou não estar vinculada a uma instituição.
- Evita implementar validações arbitrárias apenas na aplicação (ponto único de verdade no banco).

**Implementação sugerida** (duas opções):
- **Coalescência** (compatível com versões antigas):  
  ```sql
  CREATE UNIQUE INDEX uniq_enroll_tenant_person_inst
    ON enrollment (tenant_id, person_id, COALESCE(institution_id, -1));
  ```
- **Índice parcial + INCLUDE** (PG ≥ 11/15):  
  ```sql
  CREATE UNIQUE INDEX uniq_enroll_tenant_person_inst
    ON enrollment (tenant_id, person_id)
    INCLUDE (institution_id)
    WHERE institution_id IS NOT NULL;
  ```

**Impacto**:
- Rejeição de duplicatas no `INSERT/UPDATE` imediatamente.
- Simplificação das consultas e regras de negócio.

---

## 3) Exclusão Lógica (Soft Delete)
**Escolha**: Campo `deleted_at TIMESTAMPTZ` nas entidades com necessidade de desativação, como `enrollment`.

**Por quê**:
- Preserva histórico de auditoria e integridade de FKs.
- Evita reprocessos e inconsistências causadas por deleções físicas.
- Alinha-se a requisitos comuns de conformidade e rastreabilidade.

**Como usar**:
- Consultas padrão incluem `WHERE deleted_at IS NULL`.
- Criar **view** `enrollment_active` para simplificar e padronizar o filtro.
- Opcional: **RLS (Row Level Security)** para forçar invisibilidade de registros “deletados” em leitura de aplicação.

**Impacto**:
- Índices e consultas devem considerar filtros por `deleted_at`.
- Pode aumentar volume de dados “inativos”; mitigar com retenção e particionamento.

---

## 4) Índices e Performance

### 4.1 Critérios de Criação
**Escolha**: Índices em colunas usadas com alta seletividade em **filtros**, **ordenamentos** e **junções**, com atenção a multi-tenant.

**Por quê**:
- Reduz scans completos em tabelas grandes (principalmente `enrollment`).
- Melhora latência em OLTP e relatórios.

**Proposta base**:
```sql
-- Filtros frequentes por tenant/institution e ordenação por data/status
CREATE INDEX idx_enroll_tenant_inst_date_status
  ON enrollment (tenant_id, institution_id, enrollment_date DESC, status);

CREATE INDEX idx_enroll_person
  ON enrollment (person_id);

-- Índice considerando soft delete
CREATE INDEX idx_enroll_active
  ON enrollment (tenant_id, institution_id, person_id)
  WHERE deleted_at IS NULL;
```

**Impacto**:
- Maior uso de índices → menor I/O.
- Custo adicional em `INSERT/UPDATE/DELETE` (trade-off típico).

---

### 4.2 Índices Parciais e Include
**Escolha**: Índices **parciais** para reduzir tamanho e focar nos casos quentes (ex.: ativos), e **INCLUDE** (PG ≥ 11) para cobrir colunas do `SELECT` sem impactar a árvore.

**Por quê**:
- Índices menores → mais cache hit, menos manutenção.
- Queries “index-only” quando colunas consultadas estão nos índices → menos acesso ao heap.

**Impacto**:
- Ganhos significativos com pouca complexidade adicional.
- Requer análise das consultas reais para definir colunas de **INCLUDE**.

---

### 4.3 JSONB e GIN
**Escolha**: `GIN` com `jsonb_path_ops`/`jsonb_ops` em `person.metadata`.

**Por quê**:
- Consultas flexíveis por campos semânticos e busca avançada.
- `GIN` é a estrutura recomendada para indexar JSONB (alto desempenho em `@>` e `path`).

**Proposta**:
```sql
CREATE INDEX idx_person_metadata_jsonb
  ON person USING GIN (metadata jsonb_path_ops);
```

**Impacto**:
- Acelera buscas por atributos dinâmicos.
- Tamanho de índice e custo de manutenção sob escritas; ajustar conforme uso.

---

## 5) Particionamento de Dados

### 5.1 Estratégia de Particionamento
**Escolha**: Particionamento **RANGE por data** (ex.: `enrollment_date`), com granularidade **mensal** para tabelas com alta volumetria (ex.: `enrollment` com dezenas/centenas de milhões de linhas).

**Por quê**:
- **Pruning** automático (o otimizador evita ler partições fora do range consultado).
- Manutenção localizada: `VACUUM`, `REINDEX`, `ANALYZE` por partição.
- Retenção/arquivamento simplificado: `DETACH/DROP PARTITION`.

**Proposta**:
```sql
CREATE TABLE enrollment (
  id BIGSERIAL PRIMARY KEY,
  tenant_id INTEGER NOT NULL,
  institution_id INTEGER,
  person_id INTEGER NOT NULL,
  course_id INTEGER NOT NULL,
  enrollment_date DATE NOT NULL,
  status VARCHAR(20),
  deleted_at TIMESTAMPTZ DEFAULT NULL
) PARTITION BY RANGE (enrollment_date);

CREATE TABLE enrollment_2025_12 PARTITION OF enrollment
  FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');
```

**Impacto**:
- Consultas por períodos retornam muito mais rápidas.
- Índices precisam ser criados **por partição** (cuidado operacional).
- Aumenta complexidade de DDL (mitigar com scripts automatizados).

---

### 5.2 Operações e Manutenção por Partição
**Boas práticas**:
- **Script de criação automática** de partições futuras (ex.: 6–12 meses adiante).
- **Política de retenção**: `DETACH + DROP` em dados frios vencidos.
- **Índices locais** alinhados aos filtros por partição.
- Evitar partições excessivamente pequenas (overhead) ou muito grandes (piora manutenção).

---

## 6) Consultas-Alvo (Queries de Negócio)
**Guidelines** para modelar queries frequentes:

- Sempre filtrar por `tenant_id` e, quando aplicável, `institution_id`.
- Incluir `deleted_at IS NULL` para entidades com soft delete.
- Usar **JOINs** sobre chaves coerentes com FKs.
- Paginação (`LIMIT/OFFSET`) ou `keyset pagination` quando necessário.

**Exemplos (ajustar conforme schema final)**:
```sql
-- Contagem de matrículas por curso em um período
SELECT c.id AS course_id,
       c.name,
       COUNT(*) AS num_enrollments
FROM enrollment e
JOIN course c
  ON e.tenant_id = c.tenant_id
 AND e.institution_id = c.institution_id
 AND e.course_id = c.id
WHERE e.tenant_id = $1
  AND e.institution_id = $2
  AND e.deleted_at IS NULL
  AND e.enrollment_date BETWEEN $3 AND $4
GROUP BY c.id, c.name;
```

```sql
-- Listagem de alunos de um curso (com paginação)
SELECT p.id, p.name, p.birth_date, p.metadata
FROM enrollment e
JOIN person p ON p.id = e.person_id
WHERE e.tenant_id = $1
  AND e.institution_id = $2
  AND e.course_id = $3
  AND e.deleted_at IS NULL
ORDER BY p.name
LIMIT $4 OFFSET $5;
```

---

## 7) Manutenção, Autovacuum e Bloat
**Escolhas**:
- **Autovacuum tunado por tabela** para altas taxas de escrita.
- Uso de **`fillfactor`** em tabelas com muitas atualizações.
- **`REINDEX CONCURRENTLY`** em janelas de menor carga.

**Por quê**:
- Evita **bloat** (crescimento desnecessário de heap/índices).
- Mantém estatísticas atualizadas (melhora plano de execução).
- Minimiza bloqueios em produção.

**Ações sugeridas**:
```sql
ALTER TABLE enrollment SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_threshold = 1000,
  autovacuum_analyze_threshold = 500
);

ALTER TABLE person SET (fillfactor=80);
```

---

## 8) Configuração da Instância (Tuning)
**Diretrizes gerais** (ajustar à infraestrutura):

- `shared_buffers`: ~25% da RAM (limite prático 8–16 GB).
- `effective_cache_size`: 50–75% da RAM.
- `work_mem`: cauteloso e, para queries específicas, ajustar por sessão.
- `maintenance_work_mem`: 1–4 GB (reindex/vacuum/loads).
- `random_page_cost`: 1.1–1.5 (SSD/NVMe).
- `max_wal_size` maior para checkpoints menos frequentes.
- `wal_compression = on`; `wal_level = replica` (para PITR/replicação).

**Por quê**:
- Balanceia uso de memória e I/O com a carga real.
- Reduz custo de ordenações/hash e melhora throughput.

---

## 9) Alta Disponibilidade e Backups
**Escolhas**:
- **Streaming replication** (assíncrona/síncrona conforme SLA).
- **PITR** com `archive_mode=on` e catálogo de backups.
- Orquestração de failover com **Patroni** (opcional) e **pgBouncer** para pooling.

**Por quê**:
- Protege contra perda de dados e reduz RTO/RPO.
- Simplifica operações de manutenção sem downtime prolongado.

---

## 10) Segurança e Governança
**Escolhas**:
- `pg_hba.conf` estrito, **TLS** habilitado.
- Senhas com `scram-sha-256`.
- **Menor privilégio** em roles; `ALTER DEFAULT PRIVILEGES`.
- **Auditoria** via logs nativos ou **pgAudit**, conforme necessidade.

**Por quê**:
- Reduz superfície de ataque.
- Assegura conformidade e rastreabilidade operacional.

---

## 11) Observabilidade e Monitoramento
**Escolhas**:
- `pg_stat_statements` para ranking de queries.
- `log_min_duration_statement` (configurar thresholds).
- Exporters (Prometheus) e dashboards (Grafana).

**Por quê**:
- Identifica gargalos com dados concretos.
- Permite tuning iterativo e prevenção de incidentes.

---

## 12) Migrações de Esquema e Operações Seguras
**Boas práticas**:
- **`CREATE/DROP INDEX CONCURRENTLY`** para evitar bloqueios.
- Evitar DDLs que reescrevem tabelas em horário de pico (ex.: defaults não nulos em versões antigas).
- **Janela de deploy** e rollback planejado.

**Por quê**:
- Minimiza indisponibilidade e riscos durante alterações.

---

## 13) Riscos, Trade-offs e Decisões
- **Índices em excesso**: melhor leitura, pior escrita; mitigar revisando uso real.
- **Particionamento**: +complexidade DDL; grande ganho em manutenção e consultas por período.
- **Soft delete**: dados crescem mais; compensar com retenção + particionamento.
- **FKs**: +custo em escrita; integridade é prioridade em sistemas críticos.

---

## 14) Checklist de Execução

1. **Integridade**: criar PKs e FKs conforme modelo.  
2. **Unicidade**: índice único sobre `(tenant_id, person_id, institution_id)` com suporte a `NULL`.  
3. **Soft delete**: adicionar `deleted_at`, views/policies e ajustar queries.  
4. **Índices**: criar índices por filtros/ordenamentos, parciais e GIN para JSONB.  
5. **Particionamento**: particionar `enrollment` por `enrollment_date`; script para novas partições.  
6. **Autovacuum**: parâmetros por tabela; monitorar `pg_stat_progress_vacuum`.  
7. **Tuning**: ajustar memória, WAL e custos de I/O.  
8. **HA/Backup**: configurar replicação e PITR; testar restore.  
9. **Segurança**: TLS, `pg_hba.conf` mínimo, roles de menor privilégio.  
10. **Observabilidade**: `pg_stat_statements`, logs e métricas.  
11. **Migrações**: usar `CONCURRENTLY` e janelas de manutenção.  

---

## Conclusão
As escolhas acima seguem **boas práticas consolidadas** para bases **multi-tenant** com **alto volume e exigência de integridade**. Elas equilibram **performance**, **consistência**, **segurança** e **operabilidade**, com racional claro e caminhos práticos de implementação e manutenção.


---

## ✅ Contribuição
Sinta-se à vontade para abrir **issues** e enviar **pull requests** com melhorias.

## 📜 Licença
Este projeto está licenciado sob a licença MIT.
