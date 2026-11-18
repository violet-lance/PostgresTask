# 03. Plan Review

Date: 2026-11-18
Scope: everything produced so far — [task analysis](00-task.md), [grilling sessions 1–4](decisions.md), [implementation plan](02-plan.md).

The goal of this review is to catch design mistakes **before** writing the implementation, when fixing them is still cheap.

## Method

1. **Traceability check** — every requirement of the task maps to a plan stage and to a concrete verification.
2. **Technical feasibility spike** — every assumption marked as a "risk" in the plan (plus a few found during re-reading) was tested on a throwaway `postgres:17` container (PostgreSQL 17.12) instead of being trusted from memory. Spike script: [spikes/plan-review-spike.sql](spikes/plan-review-spike.sql).
3. **Adversarial re-reading** — for each decision: "how can this break?", "what does it silently rely on?", "is the requirement interpreted correctly?".
4. **Consistency check** between documents (numbers, names, ordering).

## 1. Traceability matrix

| Req | Requirement (short) | Plan stage | Main objects | How it is verified |
|-----|---------------------|-----------|--------------|--------------------|
| 1 | Partitioned T1 with the given fields, jsonb message | Stage 1 | `ops.operations`, monthly partitions, `CHECK`s on `message` | `\d+`, partition list, routing test |
| 2 | Generator, ≥100k rows, 3–4 months | Stage 3 | `ops.generate_operations` (procedure) | row count, date span, per-partition counts, `DEFAULT` empty |
| 3 | GUID uniqueness | Stage 2 | `ops.operation_guid_registry`, composite FK | duplicate GUID in another partition is rejected (also with the trigger disabled) |
| 4 | Insert job every 5 s, status 0 | Stage 4 | `ops.insert_random_operation`, pg_cron job | `cron.job_run_details` cadence, new pending rows |
| 5 | Confirm job every 3 s by seconds parity | Stage 5 | `ops.confirm_operations_by_parity`, `ops.confirm_job_log`, pg_cron job | audit log: second, parity, rows; only matching-parity ids confirmed |
| 6 | MV with totals per client & type, refreshed on each 0→1 | Stage 6 | `ops.client_type_totals`, statement trigger, `ops.mv_refresh_log` | MV == live aggregate after each run; no refresh on no-op updates |
| 7 | Replicate T1 to another instance | Stage 7 | publication / subscription | counts and sums match on both sides; new rows and status flips arrive |

Result: every requirement is covered, and each has an objective check. One gap: requirement 5 could only be verified from server logs → finding R-06.

## 2. Findings

Severity: **Blocker** — the plan would fail as written · **Major** — the plan works but has a correctness/robustness hole · **Minor** — wording, hygiene, docs.

### R-01 · Blocker · Trigger with a column list cannot use transition tables — *confirmed by spike*

The plan (Stage 6) defined `AFTER UPDATE OF status … REFERENCING OLD TABLE … NEW TABLE … FOR EACH STATEMENT`. PostgreSQL rejects it:

```
ERROR:  transition tables cannot be specified for triggers with column lists
```

**Resolution:** `AFTER UPDATE ON ops.operations REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT`. The trigger function counts the rows where `old.status = 0 AND new.status = 1` (join on `id, op_date`), so updates of other columns don't cause a refresh anyway.

### R-02 · Major · GUID uniqueness silently depended on the trigger — *fixed, confirmed by spike*

The plan had registry `PK (operation_guid)` + FK `operations(operation_guid) → registry`. If the registry trigger is disabled (e.g. `ALTER TABLE … DISABLE TRIGGER` for a bulk load, human error), two T1 rows with the same GUID in different partitions can both reference **the same** registry row → duplicate accepted. The guarantee came from procedural code, which is exactly what D-07 wanted to avoid.

**Resolution (accepted, amends D-07):** make the uniqueness fully declarative with a composite FK:

- registry: `operation_guid PRIMARY KEY`, `op_date`, `UNIQUE (operation_guid, op_date)`
- T1: `UNIQUE (operation_guid, op_date)` + `FOREIGN KEY (operation_guid, op_date) REFERENCES registry (operation_guid, op_date)`

Proof: if T1 had rows `(g, d1)` and `(g, d2)`:
- `d1 ≠ d2`: both `(g, d1)` and `(g, d2)` would have to be in the registry, which the registry PK on `g` forbids;
- `d1 = d2`: T1's `UNIQUE (operation_guid, op_date)` forbids it.

So the GUID is globally unique in T1 by constraints alone. The trigger only *fills* the registry; it no longer *guarantees* anything.

Spike evidence — same GUID, other partition, **trigger disabled**:
```
ERROR:  insert or update on table "operations_2026_11" violates foreign key constraint "operations_operation_guid_op_date_fkey"
```

> **Correction (found in Stage 2):** the first version of this finding listed `session_replication_role = replica` as one of the scenarios the composite FK protects against. **That was wrong.** FK enforcement is itself implemented with (internal) triggers, and the `replica` role disables those too. Stage 2 tested it: a duplicate GUID **was accepted** in a `replica`-role session. The composite FK protects against a disabled *user* trigger, not against the `replica` role. The `replica` role is superuser-only, and the only thing that survives it is a unique **index**, which PostgreSQL can't build across partitions. This is recorded as a known limitation in the [implementation log](04-implementation-log.md#stage-2--guid-uniqueness-requirement-3).

### R-03 · Major · Rows in `DEFAULT` block creating that month's partition — *confirmed by spike*

```
ERROR:  updated partition constraint for default partition "operations_default" would be violated by some row
```

This matters on **both** sides. The subscriber routes replicated rows through **its own** partition layout (spike: rows that are in `operations_2026_11` on the publisher landed in `operations_default` on a subscriber without a November partition). Without handling, the subscriber's maintenance job would eventually fail, or worse, data would pile up in `DEFAULT`.

**Resolution (accepted, new decision D-18):**
1. Pre-create partitions ahead (current month + 2 ahead) on both sides; on the subscriber, **before** `CREATE SUBSCRIPTION`, covering the publisher's whole data range.
2. `ops.ensure_monthly_partitions` is self-healing. If `DEFAULT` holds rows for a month being created, then in a single transaction it: creates the table standalone → moves the matching rows out of `DEFAULT` → `ATTACH PARTITION`.
3. Verification check: `DEFAULT` is empty on both instances.

### R-04 · Major · PostgreSQL 17 runs `CREATE/REFRESH MATERIALIZED VIEW` with a restricted `search_path` — *confirmed by spike*

Since PG 17, maintenance operations (including `CREATE MATERIALIZED VIEW` and `REFRESH MATERIALIZED VIEW`) execute with `search_path = pg_catalog, pg_temp`. A function used in the MV whose body relies on `search_path` fails:

```
ERROR:  relation "rates" does not exist
CONTEXT:  SQL function "f_rate" during inlining
```

**Resolution (coding rule):** all objects are schema-qualified (`ops.…`) in the MV definition and in all function bodies. In addition, every function gets an explicit `SET search_path = ops, pg_catalog` (also protects against search_path hijacking in `SECURITY DEFINER`-like contexts).

### R-05 · Info · Risks from the plan that were closed by the spike

| Risk (plan, Stage 6/7) | Result |
|------------------------|--------|
| Statement-level trigger with transition tables on a **partitioned root** | Works |
| `REFRESH MATERIALIZED VIEW CONCURRENTLY` **inside a trigger** | Works |
| The refresh sees the **same transaction's** changes | Yes — MV sum == live sum, also inside an explicit `BEGIN … COMMIT` |
| No-op updates (0 rows, or other columns) don't refresh | Confirmed — refresh log grew only on effective 0→1 updates |
| Identity column (`GENERATED BY DEFAULT`) on the subscriber accepts replicated values | Works |
| Logical replication from partitioned root into a partitioned subscriber | Works, routed by the subscriber's own layout (see R-03) |

### R-06 · Major · Requirement 5 was not observable without server logs

The plan only did `RAISE LOG` of the chosen parity. A reviewer would have to search the container logs to check that "even second → even ids" really holds.

**Resolution (accepted, new decision D-19):** `ops.confirm_job_log (run_at, run_second, parity, rows_confirmed)` — one row per job run. Primary-only, not replicated. The verification script checks that for every run the confirmed ids have the logged parity.

### R-07 · Minor · Unnecessary `pg_hba.conf` change for replication — *confirmed by spike*

The plan (Stage 7) had a `pg_hba` entry for the replica. Logical-replication walsenders connect to a concrete database, so they match ordinary `host <db> …` lines (unlike physical replication, which needs the `replication` keyword). The official image already has `host all all all scram-sha-256`. In the spike the subscriber connected with a password without any `pg_hba` changes.

**Resolution:** drop the `pg_hba` step. The dedicated `replicator` role (`LOGIN REPLICATION`, `SELECT` on T1) stays — least privilege instead of subscribing as superuser.

### R-08 · Info · Parity semantics re-checked (requirement 5)

- **Which "id"?** — the `id` field of T1 (the task's "айді"), not `client_id` from the message. Recorded explicitly to remove ambiguity.
- **Which seconds?** — the second of the job run (`now()` = transaction start). Because 60 is even, second-of-minute parity equals epoch-second parity, so there is no edge case at minute boundaries.
- **Does a 3-second cadence alternate parity?** — yes: 3 is odd, so consecutive runs alternate even/odd **regardless of how pg_cron aligns them**; if a run is delayed, the rule is still applied correctly to that run's own second. A pending row is therefore confirmed within ~2 runs (≈ 6 s).

No change to the plan.

### R-09 · Info · Why the refresh is in a trigger, not in the job function

Putting `REFRESH` inside `confirm_operations_by_parity()` would only cover updates made by the job. The requirement says "on **every** update of status 0→1" — a trigger also covers manual updates and any future code path. This confirms D-08's design; recorded as rationale.

### R-10 · Minor · Partition count wording

"4 months back from now" (2026-07-18 → 2026-11-18) touches **5** calendar months (Jul–Nov), plus pre-created future months. The generator's `ensure_monthly_partitions` call must start at `date_trunc('month', p_from)`. Wording in the plan updated.

### R-11 · Minor · Credentials

Passwords for `postgres` and `replicator` go into a `.env` file with demo defaults (referenced from compose) instead of being hard-coded in SQL. Documented as demo-only.

### R-12 · Minor · Document numbering

This review becomes `03`. The implementation log moves to `04-implementation-log.md`. Links updated in `00-task.md` and `02-plan.md`.

## 3. Changes applied as a result of this review

| Document | Change |
|----------|--------|
| [decisions.md](decisions.md) | D-07 amended (composite FK); new D-18 (DEFAULT handling), D-19 (confirm audit log), D-20 (schema-qualification rule) |
| [02-plan.md](02-plan.md) | Stage 2 composite FK; Stage 1/7 partition pre-creation & self-healing maintenance; Stage 5 audit log; Stage 6 trigger without column list; Stage 7 no `pg_hba`; `.env`; coding rules; doc numbering |
| [00-task.md](00-task.md) | Process section: review step, renumbering |

## 4. Verdict

The plan is **approved for implementation** with the amendments above. The blocker (R-01) would have been hit in Stage 6. The two robustness holes (R-02, R-03) would most likely not have shown up in a happy-path demo at all, which is why the spike was worth doing before writing any code.
