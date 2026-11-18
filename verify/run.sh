#!/usr/bin/env bash
# =============================================================================
# verify/run.sh — runs every verification against the running pair and prints a summary.
#
#   bash verify/run.sh            # after: docker compose up -d --wait
#
# Exit code 0 = all checks PASS; 1 = at least one FAIL or ERROR.
# All SQL checks run inside rolled-back transactions. The replication check commits one
# operation on the primary, exactly as the 5-second job does.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

MIN_RUNTIME_S=90   # job-based checks need ~1.5 min of job history

psql_on() { local c=$1; shift; docker exec -i "$c" psql -U postgres -d opsdb -q --no-psqlrc "$@"; }

for c in pg-primary pg-replica; do
  if ! docker exec "$c" pg_isready -h localhost -q 2>/dev/null; then
    echo "ERROR: container $c is not running/ready. Start it with: docker compose up -d --wait" >&2
    exit 1
  fi
done

# Wait until the jobs have enough history.
runtime=$(psql_on pg-primary -At -c "SELECT coalesce(extract(epoch FROM now() - min(start_time))::int, 0) FROM cron.job_run_details")
if (( runtime < MIN_RUNTIME_S )); then
  wait_s=$(( MIN_RUNTIME_S - runtime ))
  echo "Jobs have been running for ${runtime}s; waiting ${wait_s}s more so that job-based checks have history..."
  psql_on pg-primary -At -c "SELECT pg_sleep(${wait_s})" >/dev/null
fi

declare -a SUMMARY=()
TOTAL_PASS=0; TOTAL_FAIL=0

run_block() {   # $1 = title, $2 = output
  local title=$1 out=$2 pass fail
  echo; echo "=== ${title}"; echo "${out}"
  pass=$(grep -cE '\| PASS' <<<"${out}")
  fail=$(grep -cE '\| FAIL|ERROR' <<<"${out}")
  TOTAL_PASS=$((TOTAL_PASS + pass)); TOTAL_FAIL=$((TOTAL_FAIL + fail))
  SUMMARY+=("$(printf '%-52s %3s PASS  %3s FAIL' "${title}" "${pass}" "${fail}")")
}

run_block "Req 1  partitioned T1           (pg-primary)" "$(psql_on pg-primary < 01_table.sql 2>&1)"
run_block "Req 1  partitioned T1           (pg-replica)" "$(psql_on pg-replica < 01_table.sql 2>&1)"
run_block "Req 2  data generator           (pg-primary)" "$(psql_on pg-primary < 02_generator.sql 2>&1)"
run_block "Req 3  GUID uniqueness          (pg-primary)" "$(psql_on pg-primary < 03_guid_uniqueness.sql 2>&1)"
run_block "Req 4  insert job every 5 s     (pg-primary)" "$(psql_on pg-primary < 04_insert_job.sql 2>&1)"
run_block "Req 5  confirm job every 3 s    (pg-primary)" "$(psql_on pg-primary < 05_confirm_job.sql 2>&1)"
run_block "Req 6  materialized view        (pg-primary)" "$(psql_on pg-primary < 06_materialized_view.sql 2>&1)"
run_block "Req 7  logical replication      (both)"       "$(bash 07_replication.sh 2>&1)"

echo; echo "================================ SUMMARY ================================"
printf '%s\n' "${SUMMARY[@]}"
echo "-------------------------------------------------------------------------"
printf '%-52s %3s PASS  %3s FAIL\n' "TOTAL" "${TOTAL_PASS}" "${TOTAL_FAIL}"

(( TOTAL_FAIL == 0 ))
