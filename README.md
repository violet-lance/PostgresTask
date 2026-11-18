# PostgresTask

PostgreSQL test assignment: partitioned operations table, data generator, GUID uniqueness, pg_cron jobs, a materialized view refreshed on status changes, and logical replication to a second instance.

> Work in progress. The full README (requirement → object mapping, how to observe each feature) comes in the final stage.

## Quick start

Requirements: Docker with Compose v2.

```bash
docker compose up -d --wait        # builds the image, starts pg-primary (:5433) and pg-replica (:5434)
docker compose down -v             # stop and wipe data (init scripts re-run on next start)
```

Connect: `docker exec -it pg-primary psql -U postgres -d opsdb` (or `localhost:5433`, user/password `postgres`/`postgres`).

## Documentation

How the solution was designed, step by step:

1. [Task statement & breakdown](docs/00-task.md)
2. Grilling sessions: [1 — architecture](docs/01-grilling-session-1.md) · [2 — integrity & aggregation](docs/01-grilling-session-2.md) · [3 — data & replica](docs/01-grilling-session-3.md) · [4 — conventions](docs/01-grilling-session-4.md)
3. [Implementation plan](docs/02-plan.md)
4. [Plan review](docs/03-plan-review.md) (with a [feasibility spike](docs/spikes/plan-review-spike.sql))
5. [Implementation log](docs/04-implementation-log.md) · stage reviews: [stage 1](docs/reviews/stage-1-review.md) · [stage 2](docs/reviews/stage-2-review.md) · [stage 3](docs/reviews/stage-3-review.md)
6. [Decision log](docs/decisions.md)
