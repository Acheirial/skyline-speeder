#!/usr/bin/env bash
set -euo pipefail

ROUTER_NS=${SKYLINE_ROUTER_NS:-skyline-router}
SERVER_IF=${SKYLINE_ROUTER_SERVER_IF:-skyline-srv-rtr}
CLIENT_IF=${SKYLINE_ROUTER_CLIENT_IF:-skyline-cli-rtr}
RTT_MS=
RATE_MBIT=
QUEUE_BDP=1
LOSS_MODEL=random
LOSS_PCT=0
LOSS_DIRECTION=data
BURST_LENGTH=1
SEED=1
# netem "reorder PERCENT CORRELATION" on the data-direction egress only:
# a PERCENT of packets skip the delay entirely and arrive ahead of
# earlier-sent, still-delayed ones -- genuine reordering, as opposed to
# loss. Exists to give RACK a realistic path to a spurious-loss verdict
# (later proven wrong by a DSACK), which plain packet loss cannot produce.
# 0 (default) disables it -- existing scenarios are unaffected.
REORDER_PCT=0
REORDER_CORRELATION=0
TC=${SKYLINE_TC:-tc}
CLEAR=0
# --live: hot-update an ALREADY-CONFIGURED path mid-case via `tc ... change`
# instead of the normal `tc ... replace` -- see apply_egress(). `replace`
# on an existing netem regrafts the qdisc and drops every packet currently
# sitting in its delay line (plus resets the loss PRNG); `change` re-parses
# parameters onto the live qdisc in place, so in-flight queued packets and
# the connection itself are undisturbed. Requires the non-live path to have
# already been configured once in this case (the HTB class must exist).
LIVE=0
# Absolute override for the netem queue depth, bypassing the normal
# rate*rtt*queue_bdp BDP derivation. Needed for live rate-cliff updates:
# standing queue delay from that derivation is `queue_bdp * rtt_ms`,
# independent of rate_mbit -- dropping the rate alone changes nothing about
# queueing delay unless the packet count in the buffer is held constant
# while the egress rate drops (same backlog draining much slower).
QUEUE_PACKETS_OVERRIDE=

usage() {
    cat <<EOF
Usage: $0 --rtt-ms N --rate-mbit N [--queue-bdp N] [--loss-model random|gemodel]
          [--loss-pct N] [--loss-direction data|ack|symmetric]
          [--burst-length N] [--seed N]
          [--reorder-pct N] [--reorder-correlation N]
          [--live] [--queue-packets N]
       $0 --clear
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --rtt-ms) RTT_MS=$2; shift 2 ;;
        --rate-mbit) RATE_MBIT=$2; shift 2 ;;
        --queue-bdp) QUEUE_BDP=$2; shift 2 ;;
        --loss-model) LOSS_MODEL=$2; shift 2 ;;
        --loss-pct) LOSS_PCT=$2; shift 2 ;;
        --loss-direction) LOSS_DIRECTION=$2; shift 2 ;;
        --burst-length) BURST_LENGTH=$2; shift 2 ;;
        --seed) SEED=$2; shift 2 ;;
        --reorder-pct) REORDER_PCT=$2; shift 2 ;;
        --reorder-correlation) REORDER_CORRELATION=$2; shift 2 ;;
        --live) LIVE=1; shift ;;
        --queue-packets) QUEUE_PACKETS_OVERRIDE=$2; shift 2 ;;
        --clear) CLEAR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$CLEAR" -eq 0 ] && { [ -z "$RTT_MS" ] || [ -z "$RATE_MBIT" ]; }; then
    usage >&2
    exit 2
fi
if ! command -v "$TC" >/dev/null 2>&1; then
    echo "tc command is unavailable: $TC" >&2
    exit 1
fi
TC=$(realpath -- "$(command -v "$TC")")
if [ "$CLEAR" -eq 1 ]; then
    ip netns exec "$ROUTER_NS" "$TC" qdisc replace dev "$CLIENT_IF" root fq_codel
    ip netns exec "$ROUTER_NS" "$TC" qdisc replace dev "$SERVER_IF" root fq_codel
    echo "Reset Skyline Speeder router egress qdiscs to fq_codel without impairment."
    exit 0
fi
case "$LOSS_MODEL" in random|gemodel) ;; *) echo "Invalid loss model" >&2; exit 2 ;; esac
case "$LOSS_DIRECTION" in data|ack|symmetric) ;; *) echo "Invalid loss direction" >&2; exit 2 ;; esac
if awk -v pct="$REORDER_PCT" 'BEGIN { exit !(pct < 0 || pct >= 100) }'; then
    echo "Invalid --reorder-pct: must be in [0, 100)" >&2
    exit 2
fi
if awk -v corr="$REORDER_CORRELATION" 'BEGIN { exit !(corr < 0 || corr > 100) }'; then
    echo "Invalid --reorder-correlation: must be in [0, 100]" >&2
    exit 2
fi
if [ "$LIVE" -eq 0 ] && awk -v loss="$LOSS_PCT" 'BEGIN { exit !(loss > 0) }'; then
    # Only probe once, on the non-live call that first sets the case up --
    # a --live transition runs on a timing-sensitive schedule and this
    # probe's extra `tc qdisc add` round-trip has no reason to repeat.
    NETEM_HELP=$("$TC" qdisc add dev lo root netem help 2>&1 || true)
    if ! grep -qw seed <<<"$NETEM_HELP"; then
        echo "Selected tc lacks NetEm seed support: $TC" >&2
        echo "Build the pinned tool with infra/build-iproute2.sh and set SKYLINE_TC." >&2
        exit 1
    fi
fi

HALF_RTT=$(awk -v rtt="$RTT_MS" 'BEGIN { printf "%.3f", rtt / 2.0 }')
if [ -n "$QUEUE_PACKETS_OVERRIDE" ]; then
    QUEUE_PACKETS=$QUEUE_PACKETS_OVERRIDE
else
    QUEUE_PACKETS=$(awk -v rate="$RATE_MBIT" -v rtt="$RTT_MS" -v multiplier="$QUEUE_BDP" 'BEGIN {
        packets = (rate * 1000000 * rtt / 1000) / (8 * 1500)
        limit = int(packets * multiplier + 0.5)
        if (limit < 32) limit = 32
        print limit
    }')
fi

loss_arguments() {
    local percent=$1
    if awk -v loss="$percent" 'BEGIN { exit !(loss <= 0) }'; then
        return
    fi
    if [ "$LOSS_MODEL" = random ]; then
        printf 'loss random %s%% seed %s' "$percent" "$SEED"
    else
        local exit_bad
        local enter_bad
        exit_bad=$(awk -v burst_len="$BURST_LENGTH" \
            'BEGIN { printf "%.6f", 100.0 / burst_len }')
        enter_bad=$(awk -v loss="$percent" -v exit_bad="$exit_bad" 'BEGIN {
            fraction = loss / 100.0
            probability = fraction * (exit_bad / 100.0) / (1.0 - fraction)
            printf "%.6f", probability * 100.0
        }')
        printf 'loss gemodel %s%% %s%% 100%% 0%% seed %s' "$enter_bad" "$exit_bad" "$SEED"
    fi
}

apply_egress() {
    local interface=$1
    local loss=$2
    local reorder_pct=$3
    local -a netem
    local -a loss_parts
    # tc-netem(8) token order matters: limit, delay, reorder, then loss --
    # reorder must follow delay (it only has an effect because a
    # percentage of packets skip the delay) and precede the loss clause.
    netem=(limit "$QUEUE_PACKETS" delay "${HALF_RTT}ms")
    if awk -v value="$reorder_pct" 'BEGIN { exit !(value > 0) }'; then
        netem+=(reorder "${reorder_pct}%" "${REORDER_CORRELATION}%")
    fi
    if awk -v value="$loss" 'BEGIN { exit !(value > 0) }'; then
        read -r -a loss_parts <<<"$(loss_arguments "$loss")"
        netem+=("${loss_parts[@]}")
    fi
    if [ "$LIVE" -eq 1 ]; then
        # `change`, not `replace`: re-parses parameters onto the live
        # class/qdisc in place. Preserves in-flight queued packets and the
        # connection through the transition (see the top-of-file comment on
        # LIVE for why `replace` here would be destructive).
        if ! ip netns exec "$ROUTER_NS" "$TC" class change dev "$interface" parent 1: classid 1:10 \
                htb rate "${RATE_MBIT}mbit" ceil "${RATE_MBIT}mbit"; then
            if ! ip netns exec "$ROUTER_NS" "$TC" class show dev "$interface" | grep -q "classid 1:10"; then
                echo "--live on $interface but HTB class 1:10 does not exist -- run a non-live apply first" >&2
            fi
            return 1
        fi
        ip netns exec "$ROUTER_NS" "$TC" qdisc change dev "$interface" parent 1:10 handle 10: \
            netem "${netem[@]}"
        return $?
    fi
    ip netns exec "$ROUTER_NS" "$TC" qdisc replace dev "$interface" root handle 1: htb default 10
    ip netns exec "$ROUTER_NS" "$TC" class replace dev "$interface" parent 1: classid 1:10 \
        htb rate "${RATE_MBIT}mbit" ceil "${RATE_MBIT}mbit"
    ip netns exec "$ROUTER_NS" "$TC" qdisc replace dev "$interface" parent 1:10 handle 10: \
        netem "${netem[@]}"
}

DATA_LOSS=0
ACK_LOSS=0
case "$LOSS_DIRECTION" in
    data) DATA_LOSS=$LOSS_PCT ;;
    ack) ACK_LOSS=$LOSS_PCT ;;
    symmetric) DATA_LOSS=$LOSS_PCT; ACK_LOSS=$LOSS_PCT ;;
esac

# Reorder only ever applies to the data-direction (server->client) egress --
# reordering ACKs would not exercise the sender-side RACK/DSACK path this
# option exists for, and adding a direction concept for it would be
# over-engineering for a single smoke scenario's needs.
apply_egress "$CLIENT_IF" "$DATA_LOSS" "$REORDER_PCT"
apply_egress "$SERVER_IF" "$ACK_LOSS" 0

cat <<EOF
Configured Skyline Speeder path:
  RTT: ${RTT_MS} ms (${HALF_RTT} ms per egress)
  rate: ${RATE_MBIT} Mbit/s
  queue: ${QUEUE_BDP} BDP (${QUEUE_PACKETS} packets)
  loss: ${LOSS_MODEL} ${LOSS_PCT}% direction=${LOSS_DIRECTION} burst=${BURST_LENGTH}
  reorder: ${REORDER_PCT}% correlation=${REORDER_CORRELATION}% (data direction only)
  seed: ${SEED}
  tc: ${TC}
EOF
