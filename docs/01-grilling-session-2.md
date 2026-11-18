# 01. Grilling Session 2 — Integrity, Aggregation & Tooling

Date: 2026-11-18

---

## Q2.1 — Global uniqueness of the operation GUID on a partitioned table

Context: PostgreSQL requires every `UNIQUE`/`PRIMARY KEY` constraint on a partitioned table to include all partition-key columns. With RANGE partitioning by date, `UNIQUE (operation_guid, op_date)` only guarantees uniqueness of the *pair* — the same GUID with a different date would be accepted. The task asks for uniqueness by the GUID alone.

| Option | Pros | Cons |
|--------|------|------|
| **GUID registry table** — non-partitioned `operation_guid_registry (guid uuid PRIMARY KEY)`, row inserted in the same transaction as the T1 row (BEFORE INSERT trigger), plus a FK from T1 | Hard, declarative global guarantee enforced by a real B-tree unique index; race-free under concurrent inserts (the PK index serialises duplicates); independent of the GUID format | One extra write + index per insert; registry grows with T1 (needs to be pruned together with detached partitions) |
| UUIDv7 bound to the date — `CHECK (op_date = uuid_extract_timestamp(guid))` + `UNIQUE (guid, op_date)` | No extra table; since the date is a function of the GUID, the composite key is effectively global | Couples the GUID format to the business timestamp; externally supplied GUIDs (v4) would be rejected; "clever" invariant that's easy to break later |
| Trigger lookup across partitions with `pg_advisory_xact_lock(hash(guid))` | No extra table | Uniqueness lives in procedural code, not a constraint; lookup cost grows with partition count |
| Plain `UNIQUE (guid, op_date)` | Simplest | Does not satisfy the requirement |

**Decision:** GUID registry table.

**Reasoning:** uniqueness should be guaranteed by a constraint, not by convention or procedural checks. The registry is the standard workaround for global uniqueness on partitioned tables and does not restrict what GUIDs look like. T1 additionally keeps `UNIQUE (operation_guid, op_date)` as a local index for fast lookups by GUID.

> **Amended in the plan review ([R-02](03-plan-review.md)):** the FK was changed to a composite `(operation_guid, op_date)` referencing `UNIQUE (operation_guid, op_date)` in the registry. With that, uniqueness holds even if the trigger is disabled; the trigger only fills the registry.

**Implementation notes:**
- The trigger inserts into the registry; a duplicate raises `unique_violation` and aborts the T1 insert.
- The registry is **not** replicated — on the subscriber, uniqueness is inherited from the publisher (the subscriber only applies already-validated changes).

---

## Q2.2 — Materialized view refreshed "on every 0→1 status update"

| Option | Pros | Cons |
|--------|------|------|
| **Real `MATERIALIZED VIEW` + statement-level `AFTER UPDATE` trigger with transition tables → `REFRESH MATERIALIZED VIEW CONCURRENTLY`** only when at least one row actually went 0→1 | Literally satisfies "materialized view"; one refresh per UPDATE statement (not per row); `CONCURRENTLY` keeps the view readable during refresh; transition tables let us skip refreshes for no-op updates | Full recomputation on each refresh — O(table size). At ~100k rows and one refresh per 3 s this is cheap, but it would not scale to hundreds of millions of rows |
| `pg_ivm` (Incrementally Maintainable MV) | True incremental maintenance | Additional extension; technically an IMMV is a table, not a `MATERIALIZED VIEW` |
| Summary table maintained by trigger (UPSERT of deltas) | O(changed rows), scales | Deviates from the explicitly named object type "materialized view" |

**Decision:** real `MATERIALIZED VIEW` + statement-level trigger issuing `REFRESH ... CONCURRENTLY`.

**Reasoning:** the task explicitly names the object type, and the task note says explicitly named types are binding. The scalability limitation is documented; the incremental summary table is the documented upgrade path for larger volumes.

**Risks to verify during implementation:**
- Statement-level trigger with `REFERENCING OLD TABLE / NEW TABLE` on a **partitioned** table root.
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` from inside a trigger (i.e. inside the updating transaction) and that it sees the transaction's own changes.
- `CONCURRENTLY` requires a unique index on the MV → `UNIQUE (client_id, operation_type)`.

---

## Q2.3 — What does "current total amount" sum?

| Option | Pros | Cons |
|--------|------|------|
| **Only `status = 1` (confirmed) operations** | Consistent with the trigger: the total changes exactly when operations are confirmed (0→1), so "refresh on 0→1" is meaningful | Pending operations are not visible in the aggregate |
| All rows regardless of status | Simple | A 0→1 transition would not change the sum → refreshing on 0→1 would be pointless; contradicts the requirement's intent |
| Both (confirmed + pending columns) | More informative | Pending part changes on INSERT, but the MV is refreshed only on 0→1 → pending values would be stale by design |

**Decision:** sum only confirmed (`status = 1`) operations. The view also exposes the count of confirmed operations and the time of the last refresh for observability.

**Reasoning:** this is the only interpretation in which the refresh trigger (0→1) and the aggregate's semantics are coherent.

---

## Q2.4 — Role of .NET in the solution

| Option | Pros | Cons |
|--------|------|------|
| **No .NET — numbered SQL scripts + verification SQL scripts** | The task is entirely database-side; minimal noise for the reviewer; scripts are applied by `docker-entrypoint-initdb.d` | No compiled tooling |
| .NET console verifier | Nice automated report | Adds a project that doesn't demonstrate DB skills |
| EF Core migrations + xUnit integration tests | Most "enterprise" | EF Core can't model partitions, MVs, triggers, pg_cron → migrations would be 100% raw SQL; the most effort for the least signal |

**Decision:** no .NET. Pure SQL + Docker Compose + shell/SQL verification scripts.

**Reasoning:** keep the deliverable focused on what is being evaluated — PostgreSQL design. The .NET + EF Core constraint stays in force if a general-purpose language becomes necessary later.
