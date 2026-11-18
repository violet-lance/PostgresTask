# PostgreSQL 17 + pg_cron (second-level schedules, D-04).
# Pinned to the minor version the plan-review spike was run on (17.12).
FROM postgres:17.12

# The official image already has the PGDG apt repository configured.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-cron \
 && rm -rf /var/lib/apt/lists/*

# Init runner: executes /sql/common/*.sql + /sql/${INSTANCE_ROLE}/*.sql ordered by file name.
COPY --chmod=0755 run-init-sql.sh /docker-entrypoint-initdb.d/00_run-init-sql.sh
