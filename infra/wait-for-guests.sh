#!/usr/bin/env bash
set -euo pipefail

TIMEOUT=${1:-600}
SERVER_TARGET=${SKYLINE_SERVER_SSH:-skyline@127.0.0.1:2222}
CLIENT_TARGET=${SKYLINE_CLIENT_SSH:-skyline@127.0.0.1:2223}
KNOWN_HOSTS=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}
mkdir -p -- "$(dirname -- "$KNOWN_HOSTS")"

parse_target() {
    local value=$1
    local host port
    host=${value%:*}
    port=${value##*:}
    if [ "$host" = "$value" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        host=$value
        port=22
    fi
    printf '%s\n%s\n' "$host" "$port"
}

wait_for_ssh() {
    local label=$1
    local target=$2
    local host port elapsed=0
    mapfile -t parsed < <(parse_target "$target")
    host=${parsed[0]}
    port=${parsed[1]}
    while ! ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" true \
        >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            echo "$label SSH did not become ready within ${TIMEOUT}s" >&2
            return 1
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo "$label SSH ready after ${elapsed}s"
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        timeout "$TIMEOUT" cloud-init status --wait
}

remote_run() {
    local target=$1
    shift
    local host port
    mapfile -t parsed < <(parse_target "$target")
    host=${parsed[0]}
    port=${parsed[1]}
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" "$@"
}

ensure_tcpdump() {
    # research/experiments/run_matrix.py's retransmit-DSCP capture
    # (case.scenario.capture_retransmits) spawns tcpdump on both guests.
    # infra/cloud-init/user-data.template now declares it for freshly-built
    # images, but a bed built before that change only has it incidentally
    # (from the base cloud image) -- converge here rather than failing a
    # capture case with a confusing "command not found" mid-run.
    local label=$1
    local target=$2
    if remote_run "$target" command -v tcpdump >/dev/null 2>&1; then
        return 0
    fi
    echo "$label is missing tcpdump; installing"
    remote_run "$target" sudo apt-get update -qq
    remote_run "$target" sudo apt-get install -y -qq tcpdump
}

ensure_ipv6_address() {
    # cloud-init's netplan config only applies at a guest's FIRST boot.
    # infra/cloud-init/network-{server,client}.yaml gained v6 addresses
    # after this project's existing bootstrap base image (and every child
    # overlay forked from it, including ones forked long after this
    # function was written) had already run cloud-init once -- so the
    # template change alone never reaches an already-provisioned bed.
    # Converge here the same way ensure_tcpdump does, rather than leaving
    # every such bed's v6 data path silently absent (confirmed to actually
    # happen: a freshly-forked infra/kernel/run-compat-pipeline.sh overlay
    # had no v6 address at all despite the template already declaring one).
    local label=$1 target=$2 address=$3 route_prefix=$4 route_via=$5
    if remote_run "$target" ip -6 addr show dev data0 \
        | grep -qF "${address%/*}/"; then
        return 0
    fi
    echo "$label is missing its v6 address ($address); adding directly (cloud-init only applies at first boot, and this bed predates the v6 netplan config or was never regenerated since)"
    remote_run "$target" sudo ip -6 addr add "$address" dev data0
    remote_run "$target" sudo ip -6 route add "$route_prefix" via "$route_via" dev data0 \
        || true  # already present is fine, anything else surfaces on the ping check below
}

wait_for_ssh server "$SERVER_TARGET"
wait_for_ssh client "$CLIENT_TARGET"
remote_run "$SERVER_TARGET" ping -c 3 -W 2 10.20.2.2
remote_run "$CLIENT_TARGET" ping -c 3 -W 2 10.20.1.2
# v6 data path -- see infra/topology.sh's fd20:1::/64 (server) / fd20:2::/64
# (client) ULA numbering.
ensure_ipv6_address server "$SERVER_TARGET" "fd20:1::2/64" "fd20:2::/64" "fd20:1::1"
ensure_ipv6_address client "$CLIENT_TARGET" "fd20:2::2/64" "fd20:1::/64" "fd20:2::1"
# Still non-fatal even after the self-heal above: the ROUTER side
# (infra/topology.sh's own fd20:*::1 addresses + forwarding sysctl) is a
# separate, host-level prerequisite this script can't reach into, so a
# topology that predates dual-stack support would still fail here --
# that genuinely is an operator action (rerun infra/topology.sh), not
# something to paper over.
remote_run "$SERVER_TARGET" ping -6 -c 3 -W 2 fd20:2::2 \
    || echo "warning: server -> client IPv6 data path is not up (router side of infra/topology.sh may predate dual-stack support -- rerun it)" >&2
remote_run "$CLIENT_TARGET" ping -6 -c 3 -W 2 fd20:1::2 \
    || echo "warning: client -> server IPv6 data path is not up (router side of infra/topology.sh may predate dual-stack support -- rerun it)" >&2
remote_run "$SERVER_TARGET" uname -a
remote_run "$CLIENT_TARGET" uname -a
remote_run "$SERVER_TARGET" ip -brief address show data0
remote_run "$CLIENT_TARGET" ip -brief address show data0
ensure_tcpdump server "$SERVER_TARGET"
ensure_tcpdump client "$CLIENT_TARGET"
echo "Both guests and the routed data path are ready."
