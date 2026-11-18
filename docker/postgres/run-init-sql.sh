#!/usr/bin/env bash
# Runs once, on the first start of an empty data directory (docker-entrypoint-initdb.d).
#
# SQL lives in two folders: /sql/common (both instances) and /sql/${INSTANCE_ROLE}
# (primary | replica). Files from both are merged and executed in the order of their
# *file names* (01_..., 02_..., 03_...), so the numeric prefixes define one global order.
set -Eeo pipefail

if [[ "${INSTANCE_ROLE}" != "primary" && "${INSTANCE_ROLE}" != "replica" ]]; then
    echo "[init] INSTANCE_ROLE must be 'primary' or 'replica', got '${INSTANCE_ROLE}'" >&2
    exit 1
fi

mapfile -t sql_files < <(
    find /sql/common "/sql/${INSTANCE_ROLE}" -maxdepth 1 -type f -name '*.sql' -printf '%f\t%p\n' \
        | sort \
        | cut -f2
)

echo "[init:${INSTANCE_ROLE}] ${#sql_files[@]} SQL file(s) to run"

for f in "${sql_files[@]}"; do
    echo "[init:${INSTANCE_ROLE}] running ${f}"
    psql --no-psqlrc -v ON_ERROR_STOP=1 \
         --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
         -v replicator_password="${REPLICATOR_PASSWORD}" \
         -v primary_host="${PRIMARY_HOST:-pg-primary}" \
         -v primary_db="${POSTGRES_DB}" \
         -f "${f}"
done

echo "[init:${INSTANCE_ROLE}] done"
