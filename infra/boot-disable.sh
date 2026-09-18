#!/bin/sh
# Teardown counterpart of boot-enable.sh.
#
# Order matters: stop dispatching NEW flows to skyline_cc before draining,
# otherwise drain races against connections created while it waits.
#
# `ssctl drain` performs this same sysctl write itself, first, for that reason.
# It is repeated here on purpose and is not redundant: this path also has to
# work when the daemon is already gone and the control socket with it, which is
# exactly when the machine would otherwise be left with skyline_cc as its
# default and nothing registered under that name.
set -u
FALLBACK=${SKYLINE_FALLBACK_CC:-cubic}
SOCKET=${SKYLINE_SOCKET:-/run/skyline-speeder/speeder.sock}

sysctl -qw "net.ipv4.tcp_congestion_control=$FALLBACK" 2>/dev/null || true
[ -S "$SOCKET" ] && /usr/local/bin/ssctl drain --timeout 60 >/dev/null 2>&1
exit 0
