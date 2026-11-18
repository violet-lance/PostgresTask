# Review — Stage 2 (GUID uniqueness)

Date: 2026-11-18
Reviewed: commit `ac9de38` — `sql/primary/03_guid_registry.sql`, `verify/03_guid_uniqueness.sql`, Stage 2 section of the [implementation log](../04-implementation-log.md).

## Method

1. Re-reading with the question "which **legitimate** usage patterns does this break?", not only "can a duplicate get in?". A uniqueness mechanism that is correct but unusable is still a defect.
2. Every suspicion was tested on the running primary: idempotent retry, direct insert into a partition, concurrent inserts with all three outcomes of the competing transaction.
3. Operational review: privileges, destructive commands, cost per insert.

## Findings

| ID | Sev. | Finding | Resolution |
|----|------|---------|------------|
| S2-01 | **Major** | **Idempotent retries were broken.** `INSERT … ON CONFLICT (operation_guid, op_date) DO NOTHING` with an already existing operation failed with `duplicate key … operation_guid_registry_pk` instead of being skipped. A `BEFORE INSERT` trigger fires *before* the table's own conflict check, so the registry raised first. For payment operations, idempotent re-delivery by GUID is a standard pattern. | **Fixed (decision confirmed by me).** The trigger now uses `INSERT … ON CONFLICT (operation_guid) DO NOTHING` on the registry and handles three cases: new GUID → registered; GUID registered with **another** date → the trigger raises `unique_violation` (SQLSTATE 23505, same as before, with a clearer message); **same** date → the trigger does nothing and T1's `UNIQUE (operation_guid, op_date)` decides (error, or silent skip under `ON CONFLICT DO NOTHING`). Still no subtransactions. |
| S2-02 | Minor | Consequence of S2-01: a **deleted** operation can be re-inserted with the **identical** `(guid, op_date)`. Before, the GUID was blocked forever. | **Accepted, documented** in the registry's `COMMENT`. That is restoring the same operation, not reusing its GUID: the GUID stays bound to its original date, and any other date is still rejected. |
| S2-03 | Info | **Cost per insert:** PL/pgSQL trigger + registry insert into 2 unique indexes + T1's own `UNIQUE (operation_guid, op_date)` + FK lookup. All of these are B-trees over **random** UUIDv4 values, so inserts land on random leaf pages (poor cache locality at scale). | **Deferred to measurement.** The Stage 3 generator (100k rows) will show the real cost. If it matters, use time-ordered UUIDv7 (native `uuidv7()` in PG 18, a small SQL function on PG 17) → append-mostly index inserts. No premature change. |
| S2-04 | Info | **Privileges:** the trigger runs as the invoker, so an application role inserting into T1 would also need `INSERT`/`SELECT` on the registry, and could then write to it directly. | **Documented for production:** make the function `SECURITY DEFINER` (owned by the schema owner), revoke DML on the registry from application roles. Not applied: the assignment uses a single superuser and has no application roles. |
| S2-05 | Info | **Operational hazard:** `TRUNCATE ops.operation_guid_registry CASCADE` would also truncate T1, because of the FK. | Documented. A plain `TRUNCATE` (without `CASCADE`) is refused because of the FK, which is the safe default. |

## Things checked and found correct

| Check | Result |
|-------|--------|
| Direct insert into a partition (`INSERT INTO ops.operations_y2026m10 …`), bypassing the parent | Rejected: the trigger and FK are cloned onto partitions |
| Concurrent: A holds `(g, d1)` uncommitted, B inserts `(g, d2)`; **A commits** | B waits, then fails: `operation_guid … is already used by an operation dated …` — 1 row |
| Same, **A rolls back** | B waits, then succeeds — 1 row (no false positive) |
| Same date, B uses `ON CONFLICT DO NOTHING`, **A commits** | B waits, then is skipped — 1 row |
| `ON CONFLICT DO NOTHING` with a **different** date | Still rejected: the trigger's exception isn't swallowed by `DO NOTHING` |
| The error code didn't change for callers | Cross-partition duplicates still raise SQLSTATE 23505 `unique_violation` |

## Re-verification after fixes

`verify/03_guid_uniqueness.sql` extended with two checks (idempotent retry; `DO NOTHING` doesn't hide a cross-partition duplicate): **12/12 PASS**. Regression `verify/01_table.sql`: **10/10 PASS**.

## Verdict

Stage 2 is **accepted**. One major usability defect fixed, one semantic consequence documented, three operational notes recorded, one performance question carried to Stage 3 (S2-03).
