#!/usr/bin/env bash
# =============================================================================
# verify/07_replication.sh — Requirement 7: logical replication of T1 to pg-replica.
#
#   1. publisher-side checks           (07_replication_publisher.sql on pg-primary)
#   2. data fingerprint on both sides  (rows older than a cutoff, same query text)
#   3. subscriber-side checks          (07_replication_subscriber.sql on pg-replica)
#   4. live propagation                (a new operation and its 0 -> 1 confirmation
#                                       appear on the replica)
#
# Step 4 commits real data on the primary: one operation inserted exactly like the
# 5-second job does (ops.insert_random_operation()), so it is indistinguishable from
# regular job traffic.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

pri() { docker exec -i pg-primary psql -U postgres -d opsdb -q --no-psqlrc "$@"; }
rep() { docker exec -i pg-replica psql -U postgres -d opsdb -q --no-psqlrc "$@"; }

# Rows older than 30 s are settled: the confirm job confirms a row within ~6 s.
CUTOFF=$(pri -At -c "SELECT (now() - interval '30 seconds')::text")
FP_SQL="SELECT count(*) || '|' || coalesce(sum(amount), 0) || '|' || count(*) FILTER (WHERE status = 1) || '|' ||
               md5(coalesce(string_agg(id || ':' || status || ':' || amount || ':' || operation_guid || ':' || op_date || ':' || message::text,
                                       ',' ORDER BY id), ''))
        FROM ops.operations WHERE op_date < '${CUTOFF}'::timestamptz"

echo "== publisher (pg-primary)"
pri < 07_replication_publisher.sql

PUB_FP=$(pri -At -c "${FP_SQL}")
REP_FP=$(rep -At -c "${FP_SQL}")

echo "== subscriber (pg-replica)"
rep -v cutoff="${CUTOFF}" -v pub_fp="${PUB_FP}" -v rep_fp="${REP_FP}" < 07_replication_subscriber.sql

echo "== live propagation"
ID=$(pri -At -c "SELECT ops.insert_random_operation()")
T0=$(date +%s%N)

wait_for() {   # $1 = SQL returning 't' when the condition holds on the replica, $2 = timeout s
  local deadline=$(( $(date +%s) + $2 ))
  while (( $(date +%s) < deadline )); do
    [[ "$(rep -At -c "$1")" == "t" ]] && return 0
    sleep 0.2
  done
  return 1
}

if wait_for "SELECT EXISTS (SELECT 1 FROM ops.operations WHERE id = ${ID})" 10; then
  ms=$(( ($(date +%s%N) - T0) / 1000000 ))
  printf "  1 | PASS   | New operation id=%s (status 0) appears on the replica | after ~%s ms\n" "${ID}" "${ms}"
else
  printf "  1 | FAIL   | New operation id=%s (status 0) appears on the replica | not within 10 s\n" "${ID}"
fi

if wait_for "SELECT status = 1 FROM ops.operations WHERE id = ${ID}" 20; then
  ms=$(( ($(date +%s%N) - T0) / 1000000 ))
  pst=$(pri -At -c "SELECT status FROM ops.operations WHERE id = ${ID}")
  printf "  2 | PASS   | Its confirmation (0 -> 1 by the 3-s job) reaches the replica | after ~%s ms (primary status=%s)\n" "${ms}" "${pst}"
else
  printf "  2 | FAIL   | Its confirmation (0 -> 1 by the 3-s job) reaches the replica | not within 20 s\n"
fi
