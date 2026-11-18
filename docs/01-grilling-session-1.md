# 01. Grilling Session 1 — Architecture & Infrastructure

Date: 2026-11-18
Format: options with trade-offs are proposed; I pick one, and the reasoning is recorded.

---

## Q1.1 — Environment: how do we run two PostgreSQL instances (primary + replica)?

Context: no local PostgreSQL / `psql` installed; Docker is available.

| Option | Pros | Cons |
|--------|------|------|
| **Docker Compose, PostgreSQL 17** | One-command reproducible setup for the reviewer; two isolated instances on one network; custom image with `pg_cron`; PG 17 is mature and supported by every extension we may need | Requires Docker |
| Docker Compose, PostgreSQL 18 | Newer, built-in `uuidv7()` | Slightly higher extension-compatibility risk |
| Local Windows installation, two clusters on different ports | No Docker dependency | Hard for a reviewer to reproduce; pollutes the host |

**Decision:** Docker Compose with PostgreSQL 17 (primary + replica containers).

**Additional constraints set during this question:**
- All documentation and logs (`.md` files) are written in **English**.
- If a general-purpose programming language is needed anywhere, use **.NET + EF Core**.

**Reasoning:** reproducibility is the main property of a test assignment — the reviewer must be able to run `docker compose up` and see every requirement working. PG 17 avoids being on the bleeding edge for no gain.

---

## Q1.2 — Scheduler for jobs running every 5 s and every 3 s

Context: classic cron (and pgAgent) has 1-minute granularity; the task needs second-level intervals.

| Option | Pros | Cons |
|--------|------|------|
| **pg_cron** | Since v1.5 supports interval schedules like `'5 seconds'`; lives inside the DB; run history in `cron.job_run_details`; de-facto standard (RDS, Azure, Supabase) | Requires `shared_preload_libraries` → custom image/config |
| pgAgent | Classic, GUI in pgAdmin | 1-minute granularity → would need loops with `pg_sleep`; separate daemon |
| External script loop (bash/.NET) | Simple, flexible | Scheduling logic lives outside the DB; the "scheduled job" isn't a DB object |
| Long-running procedure with `LOOP` + `COMMIT` + `pg_sleep` | Pure SQL | Fragile: single session, no restart on failure, no history |

**Decision:** `pg_cron`.

**Reasoning:** native second-level schedules, run history out of the box, and the job definition is part of the database deployment.

---

## Q1.3 — Replication of T1 to another instance

| Option | Pros | Cons |
|--------|------|------|
| **Logical replication** (`PUBLICATION` / `SUBSCRIPTION`) | Replicates exactly table T1, which is what the task says; with `publish_via_partition_root = true` the subscriber can have a different (or no) partition layout; subscriber is writable (can host its own indexes/views) | Doesn't replicate DDL or sequences; requires a replica identity |
| Physical streaming replication | Byte-exact copy, simple | Replicates the *whole cluster*, not "table T1"; standby is read-only |
| Both | Shows breadth | Extra work without addressing the requirement better |

**Decision:** logical replication.

**Reasoning:** the requirement is table-scoped ("replicate table T1"), and logical replication is the table-scoped mechanism. Known limitations (no DDL replication — mitigated by `publish_via_partition_root`, so new partitions on the publisher need no subscriber changes; replica identity requirement) will be handled explicitly.

---

## Q1.4 — Partitioning scheme for T1

| Option | Pros | Cons |
|--------|------|------|
| **RANGE by date, monthly** | ~100k rows over 3–4 months → 4–5 partitions of ~25k rows each; conventional for time-series financial operations (archive/detach per month) | Need a mechanism to create future partitions |
| RANGE by date, daily | Fine-grained retention | ~120 partitions for 100k rows — overkill, planning overhead |
| RANGE monthly + `pg_partman` | Partition maintenance handled by an extension | Extra dependency for something that's ~20 lines of PL/pgSQL |

**Decision:** RANGE by date, monthly partitions.

**Planned details** (to confirm in later sessions): a `DEFAULT` partition as a safety net, plus a maintenance function (scheduled via `pg_cron`) that pre-creates upcoming monthly partitions so the 5-second insert job never lands in `DEFAULT`.

**Reasoning:** partition count proportional to data volume; monthly is the conventional granularity for operational/financial data.
