#!/usr/bin/env bash
set -euo pipefail

# Migrates the current process into the Skyline Speeder sockops cgroup before exec'ing
# the given command. This is the fix for a bug found during M1 development:
# skyline_policy.bpf.c has always attached to /sys/fs/cgroup/skyline-speeder, but nothing in
# the install scripts ever put a process into that cgroup, so the sockops
# program never actually ran for any tested flow. This script scopes the
# migration precisely to the one process the caller wants instrumented
# (the server-side iperf3 in the experiment runner), leaving management SSH
# and any other process untouched.
#
# Usage: sudo infra/run-in-skyline-cgroup.sh <command> [args...]
#
# Migrating a process into a non-root cgroup requires root (cgroup v2
# requires write access to cgroup.procs on the target and on the common
# ancestor). Root is only needed for the migration step; the command itself
# is re-executed as $SUDO_USER when available, so e.g. iperf3 keeps running
# unprivileged exactly as it did before this wrapper existed.

CGROUP=${SKYLINE_CGROUP:-/sys/fs/cgroup/skyline-speeder}

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <command> [args...]" >&2
    exit 2
fi

if [ ! -w "$CGROUP/cgroup.procs" ]; then
    echo "cgroup not writable: $CGROUP (run infra/install-guest.sh first, and run this script as root)" >&2
    exit 1
fi

echo $$ > "$CGROUP/cgroup.procs"

if [ -n "${SUDO_USER:-}" ]; then
    # Prefer runuser (part of shadow-utils/util-linux on both Debian and
    # RHEL families): it takes the argv array verbatim, so an argument
    # containing spaces or shell metacharacters survives intact. Fall back
    # to `su`, which is present even on minimal images where shadow-utils
    # may not be: su has no array form, so each argument must be re-quoted
    # (%q escapes what bash's own word splitting would otherwise undo) to
    # keep the exact same argv reaching the command.
    if command -v runuser >/dev/null 2>&1; then
        exec runuser -u "$SUDO_USER" -- "$@"
    fi
    exec su - "$SUDO_USER" -c "$(printf '%q ' "$@")"
fi
exec "$@"
