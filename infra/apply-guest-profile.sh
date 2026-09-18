#!/usr/bin/env bash
set -euo pipefail

PROFILE=${1:-}
DATA_INTERFACE=${2:-}
MODULES=${3:-}
STOCK_QDISC=${4:-fq_codel}
TCP_RECOVERY=${5:-1}
TCP_REORDERING=${6:-3}
TCP_EARLY_RETRANS=${7:-3}
SSCTL=${SSCTL:-/usr/local/bin/ssctl}
SKYLINE_SOCKET=${SKYLINE_SOCKET:-/run/skyline-speeder/speeder.sock}

if [ -z "$PROFILE" ] || [ -z "$DATA_INTERFACE" ]; then
    echo "Usage: $0 stock-cubic|controlled-cubic|bbr|skyline DATA_INTERFACE [MODULES] [STOCK_QDISC] [TCP_RECOVERY] [TCP_REORDERING] [TCP_EARLY_RETRANS]" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Guest profile changes require root." >&2
    exit 1
fi
case "$STOCK_QDISC" in fq_codel|fq|pfifo_fast) ;; *)
    echo "Unsupported stock qdisc: $STOCK_QDISC" >&2
    exit 2
esac
case "$TCP_RECOVERY" in 1|3|5|7) ;; *)
    echo "Unsupported net.ipv4.tcp_recovery mask: $TCP_RECOVERY" >&2
    exit 2
esac
if ! [[ "$TCP_REORDERING" =~ ^[0-9]+$ ]] || [ "$TCP_REORDERING" -lt 1 ] || [ "$TCP_REORDERING" -gt 300 ]; then
    echo "Unsupported net.ipv4.tcp_reordering: $TCP_REORDERING (must be 1..300)" >&2
    exit 2
fi
case "$TCP_EARLY_RETRANS" in 0|1|2|3|4) ;; *)
    echo "Unsupported net.ipv4.tcp_early_retrans: $TCP_EARLY_RETRANS" >&2
    exit 2
esac

# The kernel's stock tcp_wmem/tcp_rmem/net.core.{wmem,rmem}_max ceilings
# (4MiB on this kernel) cap throughput at rtt>=250ms regardless of
# congestion control -- every profile plateaus at nearly identical goodput
# at rtt=250ms/rate=1000Mbit, traced to sndbuf_limited in `ss -ti` output,
# consistent with the 4MiB/RTT ceiling. Raised here (applied unconditionally,
# for every profile, on every case) to cover the largest BDP a high-RTT
# scenario in this test suite exercises (1000Mbit * 400ms ~= 50MB), with
# headroom. Without this, any new high-RTT scenario would measure the
# socket buffer ceiling, not the algorithm under test.
sysctl -qw net.ipv4.tcp_wmem="4096 87380 67108864"
sysctl -qw net.ipv4.tcp_rmem="4096 87380 67108864"
sysctl -qw net.core.wmem_max=67108864
sysctl -qw net.core.rmem_max=67108864

drain_skyline() {
    if [ -S "$SKYLINE_SOCKET" ] && [ -x "$SSCTL" ]; then
        "$SSCTL" --socket "$SKYLINE_SOCKET" drain --timeout 0 >/dev/null || true
    fi
}

case "$PROFILE" in
    stock-cubic)
        drain_skyline
        modprobe tcp_cubic
        sysctl -qw net.ipv4.tcp_congestion_control=cubic
        tc qdisc replace dev "$DATA_INTERFACE" root "$STOCK_QDISC"
        ;;
    controlled-cubic)
        drain_skyline
        modprobe tcp_cubic
        modprobe sch_fq
        sysctl -qw net.ipv4.tcp_congestion_control=cubic
        tc qdisc replace dev "$DATA_INTERFACE" root fq
        ;;
    bbr)
        drain_skyline
        modprobe tcp_bbr
        modprobe sch_fq
        sysctl -qw net.ipv4.tcp_congestion_control=bbr
        tc qdisc replace dev "$DATA_INTERFACE" root fq
        ;;
    skyline)
        if [ ! -S "$SKYLINE_SOCKET" ] || [ ! -x "$SSCTL" ]; then
            echo "skyline-speederd/ssctl is unavailable" >&2
            exit 1
        fi
        modprobe sch_fq
        tc qdisc replace dev "$DATA_INTERFACE" root fq
        if [ -n "$MODULES" ]; then
            "$SSCTL" --socket "$SKYLINE_SOCKET" enable --modules "$MODULES"
        else
            "$SSCTL" --socket "$SKYLINE_SOCKET" enable --all-off
        fi
        sysctl -qw net.ipv4.tcp_congestion_control=skyline_cc
        ;;
    *)
        echo "Unknown profile: $PROFILE" >&2
        exit 2
        ;;
esac

sysctl -qw net.ipv4.tcp_recovery="$TCP_RECOVERY"
sysctl -qw net.ipv4.tcp_reordering="$TCP_REORDERING"
sysctl -qw net.ipv4.tcp_early_retrans="$TCP_EARLY_RETRANS"
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_recovery
sysctl net.ipv4.tcp_reordering
sysctl net.ipv4.tcp_early_retrans
tc -s qdisc show dev "$DATA_INTERFACE"
