#!/usr/bin/env bash
set -euo pipefail

DURATION=${1:-}
INTERVAL=${2:-1}

if [ -z "$DURATION" ]; then
    echo "Usage: $0 DURATION_SECONDS [INTERVAL_SECONDS]" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 1
fi

END_EPOCH=$(awk -v now="$(date +%s.%N)" -v duration="$DURATION" \
    'BEGIN { printf "%.9f\n", now + duration }')
while awk -v now="$(date +%s.%N)" -v end="$END_EPOCH" 'BEGIN { exit !(now < end) }'; do
    TIMESTAMP=$(date --iso-8601=ns)
    # Filtered to the iperf3 port (5201, the only port run_matrix.py ever
    # uses -- see its wait_for_iperf_server()'s identical filter) -- an
    # unfiltered `ss -tinmH` also captures the SSH control connection, which
    # silently drags median_rto_ms/p95_sampled_rtt_ms toward that idle
    # connection's numbers instead of the flow actually under test.
    SS_JSON=$(ss -tinmH '( sport = :5201 or dport = :5201 )' | jq -Rs .)
    CPU_JSON=$(sed -n '1p' /proc/stat | jq -Rs .)
    SOFTIRQ_JSON=$(jq -Rs . < /proc/softirqs)
    printf '{"timestamp":%s,"ss":%s,"cpu":%s,"softirqs":%s}\n' \
        "$(jq -Rn --arg value "$TIMESTAMP" '$value')" \
        "$SS_JSON" "$CPU_JSON" "$SOFTIRQ_JSON"
    sleep "$INTERVAL"
done
