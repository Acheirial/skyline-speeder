#!/usr/bin/env bash
set -euo pipefail

# Guest-side static/functional checks for the multi-kernel compatibility
# pipeline (see infra/kernel/run-compat-pipeline.sh). Run on the SERVER
# guest only, after skyline-speederd is installed (infra/deploy-guest.sh) but BEFORE
# it's started -- this script starts/stops it itself so it can observe the
# register -> enable -> stop -> (observed unregister behavior) sequence,
# self-healing afterward so the guest is left usable for whatever runs
# next regardless of what that sequence found.
#
# Emits one JSON object to stdout: {"checks": [{"name", "pass", "detail"},
# ...], "dmesg_new": [...]}. Never raises on an individual check failing --
# that is exactly the information the caller (run-compat-pipeline.sh) needs
# to record, not a reason for this script itself to abort. It DOES exit
# non-zero if the environment is too broken to run checks at all (e.g. no
# sudo, no ssctl binary).

EXPECTED_VERSION=${1:?"Usage: $0 EXPECTED_KERNEL_VERSION"}
SSCTL=${SKYLINE_SSCTL_BIN:-/usr/local/bin/ssctl}
SPEEDERD_CONFIG=${SKYLINE_CONFIG_PATH:-/etc/skyline-speeder/speeder.toml}

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v sudo >/dev/null || { echo "sudo is required" >&2; exit 1; }
[ -x "$SSCTL" ] || { echo "ssctl not found/executable at $SSCTL" >&2; exit 1; }

CHECKS_JSON=/tmp/skyline-compat-checks.jsonl
: > "$CHECKS_JSON"

record() {
    local name=$1 pass=$2 detail=$3
    python3 -c '
import json, sys
print(json.dumps({"name": sys.argv[1], "pass": sys.argv[2] == "true", "detail": sys.argv[3]}))
' "$name" "$pass" "$detail" >> "$CHECKS_JSON"
}

dmesg_baseline=$(sudo dmesg --ctime 2>/dev/null | wc -l || echo 0)

# --- T1: static / verifier ---

actual_version=$(uname -r)
if [ "$actual_version" = "$EXPECTED_VERSION" ]; then
    record "uname-gate" true "$actual_version"
else
    record "uname-gate" false "expected $EXPECTED_VERSION, got $actual_version"
    # Every later check would be running against the wrong kernel --
    # nothing downstream is meaningful, and continuing would misattribute
    # whatever this actually-running kernel does to $EXPECTED_VERSION.
    python3 -c '
import json
checks = [json.loads(l) for l in open("'"$CHECKS_JSON"'")]
print(json.dumps({"checks": checks, "dmesg_new": [], "aborted_after": "uname-gate"}))
'
    exit 0
fi

for path in /sys/kernel/btf/vmlinux /sys/fs/bpf /sys/fs/cgroup/cgroup.controllers; do
    # sudo, not a bare `[ -r ]` -- /sys/fs/bpf is typically mode 700 and
    # unreadable to this script's own unprivileged user even when bpffs is
    # correctly mounted and fully usable by skyline-speederd (which runs as root);
    # confirmed as a false negative against the known-good 6.18.40 guest
    # (ssctl's own root-level capabilities.bpffs check said true for the
    # exact same path this reported false on).
    if sudo test -e "$path"; then
        record "infra-present:$path" true ""
    else
        record "infra-present:$path" false "not present"
    fi
done

if actual_config_sha=$(sha256sum "/boot/config-${actual_version}" 2>/dev/null | awk '{print $1}'); then
    record "config-sha256" true "$actual_config_sha"
else
    record "config-sha256" false "/boot/config-${actual_version} unreadable"
fi

verify_log=/tmp/skyline-compat-verify-bpf.log
SPEEDERD=${SKYLINE_SPEEDERD_BIN:-/usr/local/sbin/skyline-speederd}
if [ -x "$SPEEDERD" ]; then
    # shellcheck disable=SC2024  # the redirect is deliberately the caller's,
    # not root's: $verify_log lands in /tmp owned by the invoking user, which is
    # what lets the grep and cat below read it back without sudo.
    if sudo "$SPEEDERD" --config "$SPEEDERD_CONFIG" --validate-only --verify-bpf \
        > "$verify_log" 2>&1; then
        record "verify-bpf" true "see $verify_log"
    else
        first_error=$(grep -m1 -iE "error|invalid|reject" "$verify_log" || echo "see $verify_log")
        record "verify-bpf" false "$first_error"
        # verify_log only exists on this guest, which the pipeline tears
        # down right after the smoke check -- echo the full output to
        # stderr so run-compat-pipeline.sh's ssh capture (-> smoke-static.log
        # on the host) preserves it for real debugging, not just the
        # single grep'd summary line that ends up in smoke-static.json.
        echo "--- full verify-bpf output ($verify_log) ---" >&2
        cat "$verify_log" >&2
    fi
else
    record "verify-bpf" false "skyline-speederd not found/executable at $SPEEDERD"
fi

# --- T2: struct_ops register / unregister under systemd, not a bare exec ---
# (matches how the pipeline actually runs skyline-speederd -- a raw `skyline-speederd &` here would
# validate a different code path than what's really deployed.)

sudo systemctl restart skyline-speederd.service
sleep 1
if sudo systemctl is-active --quiet skyline-speederd.service; then
    record "skyline-speederd-start" true ""
else
    record "skyline-speederd-start" false "$(sudo systemctl status skyline-speederd.service --no-pager | tail -5)"
    python3 -c '
import json
checks = [json.loads(l) for l in open("'"$CHECKS_JSON"'")]
print(json.dumps({"checks": checks, "dmesg_new": [], "aborted_after": "skyline-speederd-start"}))
'
    exit 0
fi

status_before=$(sudo "$SSCTL" status || echo '{}')
caps=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(json.dumps(d.get("status", {}).get("capabilities", {})))
except Exception as e:
    print(json.dumps({"error": str(e)}))
' "$status_before")
record "capabilities" true "$caps"
python3 -c '
import json, sys
caps = json.loads(sys.argv[1])
required = ["btf", "bpffs", "cgroup_v2", "fq_available", "struct_ops", "fallback_cc_available"]
missing = [k for k in required if not caps.get(k)]
print("true" if not missing else "false", ",".join(missing))
' "$caps" | { read -r ok missing; record "capabilities-hard-gate" "$ok" "$missing"; }

sudo "$SSCTL" enable >/dev/null 2>&1 || true
sleep 1
if grep -q '\bskyline_cc\b' /proc/sys/net/ipv4/tcp_available_congestion_control; then
    record "cc-register" true "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
else
    record "cc-register" false "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
fi

sudo systemctl stop skyline-speederd.service
sleep 1
if grep -q '\bskyline_cc\b' /proc/sys/net/ipv4/tcp_available_congestion_control; then
    # A clean `systemctl stop` is expected to unregister the struct_ops via
    # skyline-speederd's own SIGTERM handling. If skyline_cc is still listed here with no
    # live daemon behind it, that's a real leak worth recording (a later
    # `ssctl enable` would fail with "File exists" until it's cleared) --
    # this is exactly the kind of struct_ops unregister-on-process-exit
    # behavior worth comparing across kernel versions. The guest MUST NOT
    # be left in this state for whatever pipeline stage runs next on it
    # (the data-plane smoke manifest's compat-skyline-full profile needs a
    # working skyline_cc), so self-heal immediately via `bpftool struct_ops
    # unregister` rather than requiring a reboot.
    orphan_id=$(sudo bpftool struct_ops list | awk '/skyline_cc/ {print $1}' | tr -d :)
    if [ -n "$orphan_id" ] && sudo bpftool struct_ops unregister id "$orphan_id"; then
        record "cc-unregister" false "skyline_cc leaked after systemctl stop (self-healed via bpftool struct_ops unregister id $orphan_id)"
    else
        record "cc-unregister" false "skyline_cc leaked after systemctl stop AND self-heal failed -- guest may need a reboot before further skyline_cc use"
    fi
else
    record "cc-unregister" true ""
fi

dmesg_file=/tmp/skyline-compat-dmesg-new.txt
sudo dmesg --ctime 2>/dev/null | tail -n "+$((dmesg_baseline + 1))" > "$dmesg_file" || true
dmesg_bad=$(grep -iE '\bwarn|\bbug\b|rcu stall|call trace' "$dmesg_file" || true)
if [ -z "$dmesg_bad" ]; then
    record "dmesg-clean" true ""
else
    record "dmesg-clean" false "$(printf '%s' "$dmesg_bad" | head -3)"
fi

# dmesg_new read from a file, not shell-interpolated into the python source
# -- dmesg output is arbitrary kernel/driver text and embedding it as a
# quoted string literal in generated code is exactly the kind of injection
# risk that reading it as data sidesteps entirely.
python3 -c '
import json
checks = [json.loads(l) for l in open("'"$CHECKS_JSON"'")]
with open("'"$dmesg_file"'") as f:
    dmesg_new = f.read().splitlines()
print(json.dumps({"checks": checks, "dmesg_new": dmesg_new}))
'
