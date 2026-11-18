# Decision Log

One line per decision. Details, alternatives and reasoning are in the linked session files.

| ID | Topic | Decision | Source |
|----|-------|----------|--------|
| D-01 | Environment | Docker Compose, two PostgreSQL 17 containers (publisher + subscriber) | [Session 1 · Q1.1](01-grilling-session-1.md#q11--environment-how-do-we-run-two-postgresql-instances-primary--replica) |
| D-02 | Docs language | All `.md` docs and logs in English | [Session 1 · Q1.1](01-grilling-session-1.md) |
| D-03 | General-purpose language | .NET + EF Core, only if needed | [Session 1 · Q1.1](01-grilling-session-1.md) |
| D-04 | Scheduler | `pg_cron` with second-level interval schedules | [Session 1 · Q1.2](01-grilling-session-1.md) |
| D-05 | Replication | Logical replication, `publish_via_partition_root = true` | [Session 1 · Q1.3](01-grilling-session-1.md) |
| D-06 | Partitioning | RANGE by `op_date`, monthly, + `DEFAULT` partition + scheduled pre-creation of future partitions | [Session 1 · Q1.4](01-grilling-session-1.md) |
| D-07 | GUID uniqueness | Non-partitioned GUID registry table (PK) filled by BEFORE INSERT trigger + FK from T1 | [Session 2 · Q2.1](01-grilling-session-2.md) |
| D-08 | Aggregation | Real `MATERIALIZED VIEW`, refreshed `CONCURRENTLY` by a statement-level trigger only when rows went 0→1 | [Session 2 · Q2.2](01-grilling-session-2.md) |
| D-09 | Aggregate semantics | Sum of confirmed (`status = 1`) operations only | [Session 2 · Q2.3](01-grilling-session-2.md) |
| D-10 | Tooling | No .NET; SQL scripts + Docker Compose + verification scripts | [Session 2 · Q2.4](01-grilling-session-2.md) |
| D-11 | Historical statuses | Older than 24 h → 1; last 24 h → mostly 0 | [Session 3 · Q3.1](01-grilling-session-3.md) |
| D-12 | Generator | Procedure, set-based batches with `COMMIT` per batch | [Session 3 · Q3.2](01-grilling-session-3.md) |
| D-13 | Message domain | Deterministic client/account pool + `CHECK` constraints on jsonb | [Session 3 · Q3.3](01-grilling-session-3.md) |
| D-14 | Subscriber shape | Same partitioned layout + own partition-maintenance job; no business jobs, no registry | [Session 3 · Q3.4](01-grilling-session-3.md) |
| D-15 | Naming | Schema `ops`, table `ops.operations`, meaningful columns, mapping in docs + `COMMENT ON` | [Session 4 · Q4.1](01-grilling-session-4.md) |
| D-16 | MV refresh failure | Abort the whole UPDATE (strong consistency, retried by next run) | [Session 4 · Q4.2](01-grilling-session-4.md) |
| D-17 | Git | One commit per stage, no push | [Session 4 · Q4.3](01-grilling-session-4.md) |
