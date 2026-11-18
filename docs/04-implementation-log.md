# 04. Implementation Log

Chronological log of the implementation: what was done per stage of the [plan](02-plan.md), how it was verified, problems hit, and deviations from the plan.

---

## Stage 0 — Environment

Date: 2026-11-18 · Commit: `chore: docker environment (stage 0)`

### What was done

| File | Purpose |
|------|---------|
| `.gitattributes` | `eol=lf` for everything (except `*.ps1`): scripts run inside Linux containers, and on Windows git would otherwise check them out with CRLF |
| `.env.example`, `.gitignore` | Demo credentials and ports; `.env` itself is git-ignored |
| `docker/postgres/Dockerfile` | `postgres:17.12` + `postgresql-17-cron` from the PGDG repo; copies the init runner |
| `docker/postgres/run-init-sql.sh` | Init runner (see deviation 1) |
| `docker-compose.yml` | `pg-primary` (:5433) and `pg-replica` (:5434), shared image, healthcheck, replica `depends_on: service_healthy` |
| `sql/{common,primary,replica}/`, `verify/` | Empty folders for the next stages |

### Deviations from the plan

1. **Init runner instead of mounting files straight into `/docker-entrypoint-initdb.d`.**
   The plan assumed mounting the common and role-specific files into the init directory. However, the entrypoint only runs files at the top level of that directory (subdirectories are ignored), and it can't pass `psql` variables. `run-init-sql.sh` (baked into the image) merges `/sql/common/*.sql` and `/sql/${INSTANCE_ROLE}/*.sql`, sorts them **by file name**, and runs each with `ON_ERROR_STOP=1`. It passes `replicator_password`, `primary_host` and `primary_db` as psql variables, so the SQL contains no credentials or hostnames. The SQL folders are bind-mounted read-only, so editing SQL needs no image rebuild (only `docker compose down -v && up`).
2. **`.env.example` + compose defaults instead of a committed `.env`** (refines R-11).
   `docker-compose.yml` uses `${VAR:-default}`, so `docker compose up` works on a fresh clone without any file, and a committed `.env` can't accidentally become the place for real secrets.
3. **Image pinned to `postgres:17.12`** (plan said `postgres:17`): the same minor version the plan-review spike ran on, so the spike results stay valid.

### Verification

```
$ docker compose up -d --wait
 Container pg-primary Healthy
 Container pg-replica Healthy
```

| Check | pg-primary | pg-replica |
|-------|-----------|-----------|
| `server_version` | 17.12 | 17.12 |
| `shared_preload_libraries` | `pg_cron` | `pg_cron` |
| `cron.database_name` / `cron.use_background_workers` | `opsdb` / `on` | `opsdb` / `on` |
| `max_worker_processes` | 32 | 32 |
| `wal_level` | **`logical`** | `replica` (not a publisher, default is enough) |
| `TimeZone` | UTC | UTC |
| `CREATE EXTENSION pg_cron` (in a rolled-back tx) | 1.6 | 1.6 |
| `cron.schedule(..., '5 seconds', ...)` accepted | yes | yes |

The replica can reach the primary over the compose network: `pg_isready -h pg-primary` → `accepting connections`.

### Observations

- During init, the log contains `FATAL: database "opsdb" does not exist` and `pg_cron launcher exited with exit code 1`. This is harmless: the entrypoint's temporary init server starts **before** it creates `POSTGRES_DB`, so the pg_cron launcher (configured with `cron.database_name=opsdb`) can't connect yet. On the final server start, `pg_cron scheduler started` appears as expected.
- Init scripts run only on an **empty data volume**. To re-run them after changing SQL: `docker compose down -v && docker compose up -d --wait`.
