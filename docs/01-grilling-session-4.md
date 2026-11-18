# 01. Grilling Session 4 — Conventions & Failure Semantics

Date: 2026-11-18

---

## Q4.1 — Naming of the table and fields

Context: the task says names must not be taken literally unless explicitly given.

| Option | Pros | Cons |
|--------|------|------|
| **Meaningful names + explicit mapping** — schema `ops`, table `ops.operations`; columns `op_date`, `id`, `amount`, `status`, `operation_guid`, `message` | Self-documenting schema; matches how a real system would be named; mapping to the task terms is kept in docs and `COMMENT ON` | Reviewer needs the mapping to find "T1" |
| Keep `t1`, meaningful column names | Instantly recognisable | Half-literal, inconsistent |
| Everything literal | Recognisable | Contradicts the task's own instruction |

**Decision:** meaningful names, with a mapping table in the docs and `COMMENT ON TABLE/COLUMN` referencing the task terms.

| Task term | Object |
|-----------|--------|
| T1 | `ops.operations` (partitioned) |
| "дата" (date) | `op_date timestamptz` — partition key |
| "айді" (id) | `id bigint` identity |
| "сума" (amount) | `amount numeric(14,2)` |
| "стан" (status) | `status smallint` (0 = pending, 1 = confirmed) |
| "гуід операції" (operation guid) | `operation_guid uuid` |
| "повідомлення" (message, jsonb) | `message jsonb` with `account_number`, `client_id`, `operation_type` |
| materialized view | `ops.client_type_totals` |

---

## Q4.2 — What happens if the MV refresh fails inside the 0→1 UPDATE?

Context: the refresh runs in an `AFTER` statement trigger, i.e. in the same transaction as the status update.

| Option | Pros | Cons |
|--------|------|------|
| **Let the error abort the whole UPDATE** | Strong consistency: the MV always reflects exactly the committed confirmed operations; the next job run (3 s later) naturally retries; this is PostgreSQL's default behaviour, no extra code | A broken MV blocks confirmations until fixed |
| Catch the error, mark MV as stale, refresh later via a separate job | Confirmations never blocked | MV can silently lag; more moving parts; contradicts "refreshed on every update" |

**Decision:** abort the whole UPDATE (default transactional behaviour).

**Reasoning:** the requirement couples the two operations ("refresh on every 0→1"), so they should succeed or fail together. A failure becomes visible in `cron.job_run_details` instead of being hidden.

---

## Q4.3 — Git workflow during implementation

**Decision:** one commit per stage — docs/grilling, plan, then one commit per task requirement (or tightly related group). No push.

**Reasoning:** the commit history becomes a second, chronological view of the thought process, complementing the docs.
