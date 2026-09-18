#!/usr/bin/env bash
set -euo pipefail

# Multi-kernel compatibility pipeline. Correctness/adaptability smoke, NOT a
# performance matrix -- see research/experiments/manifests/kernel-compat-
# smoke.toml's header.
#
# Usage: $0 <plan|build|test|report|all> CAMPAIGN_ROOT [flags]
#   --versions v1,v2,...     default: 6.1.180,6.6.148,6.12.101,6.18.42,7.1.6
#   --accel kvm|tcg          default: kvm
#   --resume                 skip versions whose state.json already says
#                            pass with a matching identity (see below)
#   --keep-going             default ON: a version's failure doesn't stop
#                            the rest. Pass --no-keep-going to stop at the
#                            first failure instead.
#   --pause-on-failure       leave the VM pair running (don't tear down) on
#                            a `test`-phase failure, so it can be inspected
#                            over SSH before anyone decides what to do next.
#
# Two phases, run separately or together via `all`:
#   build -- fetch + build all kernels' .deb packages. No VMs touched.
#   test  -- for each successfully-built version: fork a child overlay,
#            boot it, install the kernel, pin GRUB, reboot, run the smoke
#            checks, tear down.
#   report -- render report.md/summary.json from whatever state.json files
#            exist so far (safe to run after a partial/failed run).
#
# State: one versions/<version>/state.json per version (schema documented
# in research/experiments/render_kernel_compat_report.py). --resume compares
# state.identity against the CURRENT identity (repo rev + the sha256 of the
# scripts this pipeline itself depends on) -- a match means skip the whole
# version; a mismatch means the kernel build itself is still reusable (it
# doesn't depend on Skyline Speeder's own source) but every stage from `overlay` onward
# reruns, since deploy-guest.sh/compat-smoke-guest.sh may have changed.

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd)
cd "$REPO_ROOT"
PYTHON=${SKYLINE_PYTHON:-.venv/bin/python}
STATE_PY="$SELF_DIR/compat_state.py"

PHASE=${1:-}
CAMPAIGN_ROOT=${2:-}
if [ -z "$PHASE" ] || [ -z "$CAMPAIGN_ROOT" ]; then
    echo "Usage: $0 <plan|build|test|report|all> CAMPAIGN_ROOT [flags]" >&2
    exit 2
fi
shift 2

VERSIONS_CSV="6.1.180,6.6.148,6.12.101,6.18.42,7.1.6"
ACCEL=kvm
RESUME=0
KEEP_GOING=1
PAUSE_ON_FAILURE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --versions) VERSIONS_CSV=$2; shift 2 ;;
        --accel) ACCEL=$2; shift 2 ;;
        --resume) RESUME=1; shift ;;
        --keep-going) KEEP_GOING=1; shift ;;
        --no-keep-going) KEEP_GOING=0; shift ;;
        --pause-on-failure) PAUSE_ON_FAILURE=1; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done
IFS=',' read -r -a VERSIONS <<< "$VERSIONS_CSV"

# bpftool lives in /usr/sbin on this host and isn't on this shell's default
# PATH -- needed for `make bpf`'s vmlinux.h generation below, and for
# run_matrix.py's own host-side capability probe (snapshot_environment()).
export PATH="$PATH:/usr/sbin:/sbin"

CAMPAIGN_ROOT=$(realpath -m -- "$CAMPAIGN_ROOT")
VERSIONS_DIR="$CAMPAIGN_ROOT/versions"
mkdir -p -- "$VERSIONS_DIR"

SERVER_TARGET=${SKYLINE_SERVER_SSH:-skyline@127.0.0.1:2222}
CLIENT_TARGET=${SKYLINE_CLIENT_SSH:-skyline@127.0.0.1:2223}
SKYLINE_TC_BIN=${SKYLINE_TC:-$REPO_ROOT/build/tools/tc-iproute2-6.18.0}

log() { printf '[%s] %s\n' "$(date --utc +%H:%M:%S 2>/dev/null || echo '--:--:--')" "$1" >&2; }

state_path() { echo "$VERSIONS_DIR/$1/state.json"; }

patch_state() {
    # patch_state VERSION JSON
    local version=$1 json=$2
    "$PYTHON" "$STATE_PY" init "$(state_path "$version")" "$version"
    printf '%s' "$json" | "$PYTHON" "$STATE_PY" patch "$(state_path "$version")"
}

get_state() {
    "$PYTHON" "$STATE_PY" get "$(state_path "$1")" "$2"
}

current_identity_json() {
    local repo_rev repo_dirty build_sha deploy_sha smoke_sha
    repo_rev=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    if [ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]; then
        repo_dirty=true
    else
        repo_dirty=false
    fi
    build_sha=$(sha256sum "$SELF_DIR/build.sh" | awk '{print $1}')
    deploy_sha=$(sha256sum "$SELF_DIR/deploy.sh" | awk '{print $1}')
    smoke_sha=$(sha256sum "$SELF_DIR/compat-smoke-guest.sh" | awk '{print $1}')
    printf '{"repo_rev":"%s","repo_dirty":%s,"build_sh_sha256":"%s","deploy_sh_sha256":"%s","smoke_sh_sha256":"%s"}' \
        "$repo_rev" "$repo_dirty" "$build_sha" "$deploy_sha" "$smoke_sha"
}

identity_matches() {
    local version=$1 current=$2 stored
    stored=$(get_state "$version" identity)
    [ -n "$stored" ] && [ "$stored" = "$current" ]
}

stage_pass() { get_state "$1" "stages.$2.status" | grep -qx pass; }
# A stage intentionally left at "skip" (e.g. overlay/fetch reusing an
# already-built artifact from an earlier run) is not a failure -- only
# "fail" should count against the version's overall result.
stage_ok() { get_state "$1" "stages.$2.status" | grep -qxE 'pass|skip'; }

fail_stage() {
    # fail_stage VERSION STAGE MESSAGE
    local version=$1 stage=$2 message=$3
    patch_state "$version" "$(printf '{"overall":"fail","stages":{"%s":{"status":"fail","detail":%s}},"failure":{"stage":"%s","message":%s}}' \
        "$stage" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$message")" \
        "$stage" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$message")")"
    log "FAIL $version @ $stage: $message"
}

pass_stage() {
    local version=$1 stage=$2 detail=${3:-}
    patch_state "$version" "$(printf '{"stages":{"%s":{"status":"pass","detail":%s}}}' \
        "$stage" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$detail")")"
}

skip_stage() {
    local version=$1 stage=$2 detail=${3:-}
    patch_state "$version" "$(printf '{"stages":{"%s":{"status":"skip","detail":%s}}}' \
        "$stage" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$detail")")"
}

# ---------------------------------------------------------------- plan ----

do_plan() {
    log "campaign root: $CAMPAIGN_ROOT"
    log "versions: ${VERSIONS[*]}"
    log "accel: $ACCEL  resume: $RESUME  keep_going: $KEEP_GOING  pause_on_failure: $PAUSE_ON_FAILURE"
    local need_gib=$(( ${#VERSIONS[@]} * 16 + 20 ))
    local avail_gib
    avail_gib=$(df -BG --output=avail "$REPO_ROOT" | tail -1 | tr -dc '0-9')
    log "disk: need ~${need_gib}GiB headroom, ${avail_gib}GiB available on $REPO_ROOT's filesystem"
    if [ "$avail_gib" -lt "$need_gib" ]; then
        echo "Insufficient disk headroom (need ~${need_gib}GiB, have ${avail_gib}GiB). Override by editing this check if you are sure." >&2
        exit 1
    fi
    if [ ! -f "$CAMPAIGN_ROOT/campaign.json" ]; then
        local qemu_version skyline_tc_version host_cpu host_mem
        qemu_version=$(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo unknown)
        skyline_tc_version=$("$SKYLINE_TC_BIN" -V 2>/dev/null || echo unknown)
        host_cpu=$(nproc 2>/dev/null || echo unknown)
        host_mem=$(free -m 2>/dev/null | awk '/^Mem:/ {print $2}' || echo unknown)
        python3 -c '
import json, sys
print(json.dumps({
    "git_rev": sys.argv[1], "accel": sys.argv[2], "qemu_version": sys.argv[3],
    "skyline_tc_version": sys.argv[4], "host_cpu": sys.argv[5], "host_memory_mib": sys.argv[6],
    "bootstrap_overlay": sys.argv[7],
}, indent=2))
' "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" "$ACCEL" "$qemu_version" \
            "$skyline_tc_version" "$host_cpu" "$host_mem" "$REPO_ROOT/build/images/server.qcow2" \
            > "$CAMPAIGN_ROOT/campaign.json"
        log "wrote $CAMPAIGN_ROOT/campaign.json"
    fi
    for version in "${VERSIONS[@]}"; do
        "$PYTHON" "$STATE_PY" init "$(state_path "$version")" "$version"
        log "  $version -> overall=$(get_state "$version" overall)"
    done
}

# --------------------------------------------------------------- build ----

do_build_one() {
    local version=$1
    local identity; identity=$(current_identity_json)
    if [ "$RESUME" = 1 ] && stage_pass "$version" build && identity_matches "$version" "$identity"; then
        log "$version: build already pass, identity matches -- skipping"
        return 0
    fi
    # Reset overall/failure from any earlier attempt -- fail_stage sets
    # both as an immediate signal when a stage fails, but nothing clears
    # them back out on a later successful retry of that same stage
    # (per-stage status below IS correctly overwritten either way; this is
    # just the top-level convenience fields, which --resume's `overall`
    # check and a human skimming state.json both read).
    patch_state "$version" "{\"identity\":$identity,\"overall\":\"running\",\"failure\":null}"

    local archive="build/kernel/linux-${version}.tar.xz"
    if [ -f "$archive" ] && [ -f "$archive.sha256" ]; then
        skip_stage "$version" fetch "archive already present"
    else
        log "$version: fetching source"
        if SKYLINE_KERNEL_VERSION="$version" infra/kernel/fetch-source.sh --allow-proxy \
            > "$VERSIONS_DIR/$version/fetch.log" 2>&1; then
            pass_stage "$version" fetch
        else
            fail_stage "$version" fetch "download failed, see fetch.log"
            return 1
        fi
    fi

    local debs
    debs=$(find build/kernel -maxdepth 1 -name "linux-image-*${version}*.deb" ! -name "*-dbg_*" 2>/dev/null | wc -l)
    if [ "$debs" -ge 1 ] && [ -f "build/kernel/config-${version}" ]; then
        skip_stage "$version" build "deb package(s) already present"
    else
        log "$version: building kernel (this takes a long time)"
        local build_log="$VERSIONS_DIR/$version/build.log"
        # Pin the same base config across all versions -- otherwise build.sh's
        # own default (/boot/config-$(uname -r), the HOST's own bare-metal
        # kernel config) silently applies, which drifts the base out from
        # under the intended cross-version comparability and was never
        # noticed until a real build failure prompted checking .pre-olddefconfig
        # snapshots against it.
        if SKYLINE_KERNEL_VERSION="$version" \
            SKYLINE_KERNEL_BASE_CONFIG="${SKYLINE_KERNEL_BASE_CONFIG:-build/kernel/config-guest-6.8}" \
            infra/kernel/build.sh > "$build_log" 2>&1; then
            pass_stage "$version" build
        else
            local tail_msg; tail_msg=$(tail -20 "$build_log")
            fail_stage "$version" build "kernel build failed, see build.log; tail: $tail_msg"
            return 1
        fi
    fi

    for artifact_file in "build/kernel/listnewconfig-${version}.txt" "build/kernel/diffconfig-${version}.txt"; do
        [ -f "$artifact_file" ] && cp "$artifact_file" "$VERSIONS_DIR/$version/"
    done
    if [ -f "build/kernel/config-${version}" ]; then
        local config_sha; config_sha=$(sha256sum "build/kernel/config-${version}" | awk '{print $1}')
        patch_state "$version" "{\"artifacts\":{\"config_sha256\":\"$config_sha\"}}"
    fi
    if [ -f "build/kernel/vmlinux-${version}.sha256" ]; then
        local vmlinux_sha; vmlinux_sha=$(awk '{print $1}' "build/kernel/vmlinux-${version}.sha256")
        patch_state "$version" "{\"artifacts\":{\"vmlinux_sha256\":\"$vmlinux_sha\"}}"
    fi
    return 0
}

do_build() {
    local failures=0
    for version in "${VERSIONS[@]}"; do
        if ! do_build_one "$version"; then
            failures=$((failures + 1))
            [ "$KEEP_GOING" = 1 ] || { log "stopping after $version's build failure (--no-keep-going)"; break; }
        fi
    done
    log "build phase: ${#VERSIONS[@]} version(s), $failures failure(s)"
    [ "$failures" -eq 0 ]
}

# ---------------------------------------------------------------- test ----

remote_run() {
    local target=$1; shift
    local host=${target%:*} port=${target##*:}
    [ "$host" = "$target" ] && port=22
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}" \
        -p "$port" "$host" "$@"
}
remote_scp_to() {
    local target=$1 src=$2 dst=$3
    local host=${target%:*} port=${target##*:}
    [ "$host" = "$target" ] && port=22
    scp -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}" \
        -P "$port" -- "$src" "$host:$dst"
}

teardown_vms() {
    infra/run-vms.sh stop --accel "$ACCEL" --confirm-stop >&2 || true
}

do_test_one() {
    local version=$1
    if ! stage_pass "$version" build; then
        log "$version: build did not pass -- skipping test phase entirely"
        skip_stage "$version" overlay "build stage did not pass"
        return 1
    fi
    local identity; identity=$(current_identity_json)
    if [ "$RESUME" = 1 ] && [ "$(get_state "$version" overall)" = pass ] && identity_matches "$version" "$identity"; then
        log "$version: overall already pass, identity matches -- skipping test phase"
        return 0
    fi
    patch_state "$version" "{\"identity\":$identity,\"overall\":\"running\",\"failure\":null}"

    local vdir="$VERSIONS_DIR/$version"
    local image_dir="build/images/compat-$version"

    # --- overlay ---
    if [ -f "$image_dir/server.qcow2" ] && [ -f "$image_dir/client.qcow2" ]; then
        skip_stage "$version" overlay "child overlay already exists"
    else
        rm -rf "$image_dir"  # partial overlay from a prior failed attempt
        if SKYLINE_VM_DISK_GIB=32 infra/prepare-child-images.sh \
            build/images/server.qcow2 build/images/client.qcow2 "$image_dir" \
            > "$vdir/overlay.log" 2>&1; then
            pass_stage "$version" overlay
        else
            fail_stage "$version" overlay "prepare-child-images.sh failed, see overlay.log"
            return 1
        fi
    fi

    # --- boot (on the base/bootstrap kernel, before installing the target) ---
    teardown_vms
    if SKYLINE_SERVER_IMAGE="$REPO_ROOT/$image_dir/server.qcow2" \
        SKYLINE_CLIENT_IMAGE="$REPO_ROOT/$image_dir/client.qcow2" \
        infra/run-vms.sh start --accel "$ACCEL" > "$vdir/boot.log" 2>&1 \
        && infra/wait-for-guests.sh 600 >> "$vdir/boot.log" 2>&1; then
        pass_stage "$version" boot
    else
        fail_stage "$version" boot "VM did not come up, see boot.log"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- kernel-install (deploy + pin GRUB + reboot) ---
    if SKYLINE_KERNEL_VERSION="$version" infra/kernel/deploy.sh build/kernel --confirm-install-kernel \
        > "$vdir/kernel-install.log" 2>&1; then
        remote_run "$SERVER_TARGET" sudo reboot >/dev/null 2>&1 || true
        remote_run "$CLIENT_TARGET" sudo reboot >/dev/null 2>&1 || true
        sleep 5
        if infra/wait-for-guests.sh 600 >> "$vdir/kernel-install.log" 2>&1; then
            pass_stage "$version" kernel-install
        else
            fail_stage "$version" kernel-install "guests did not come back after reboot, see kernel-install.log"
            [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
            return 1
        fi
    else
        fail_stage "$version" kernel-install "deploy.sh failed, see kernel-install.log"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- uname-gate (hard: wrong kernel invalidates every later check) ---
    local actual_version
    actual_version=$(remote_run "$SERVER_TARGET" uname -r 2>/dev/null || echo "")
    if [ "$actual_version" = "$version" ]; then
        pass_stage "$version" uname-gate "$actual_version"
    else
        fail_stage "$version" uname-gate "expected $version, server booted $actual_version -- GRUB pin likely did not take; not running any further checks against the wrong kernel"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- bpf-compile (force-regenerate vmlinux.h -- see Makefile timestamp trap) ---
    rm -f bpf/include/vmlinux.h build/bpf/*.bpf.o
    if VMLINUX_BTF="$REPO_ROOT/build/kernel/out-${version}/vmlinux" make bpf \
        > "$vdir/bpf-compile.log" 2>&1; then
        pass_stage "$version" bpf-compile
        local h_sha; h_sha=$(sha256sum bpf/include/vmlinux.h | awk '{print $1}')
        patch_state "$version" "{\"artifacts\":{\"vmlinux_h_sha256\":\"$h_sha\"}}"
    else
        fail_stage "$version" bpf-compile "make bpf failed against this kernel's BTF, see bpf-compile.log"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- skyline-deploy ---
    if VMLINUX_BTF="$REPO_ROOT/build/kernel/out-${version}/vmlinux" infra/deploy-guest.sh --confirm-install \
        > "$vdir/skyline-deploy.log" 2>&1; then
        pass_stage "$version" skyline-deploy
    else
        fail_stage "$version" skyline-deploy "deploy-guest.sh failed, see skyline-deploy.log"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- smoke-static ---
    remote_scp_to "$SERVER_TARGET" infra/kernel/compat-smoke-guest.sh /tmp/compat-smoke-guest.sh
    local smoke_json
    smoke_json=$(remote_run "$SERVER_TARGET" "chmod +x /tmp/compat-smoke-guest.sh && /tmp/compat-smoke-guest.sh $version" 2>"$vdir/smoke-static.log") || true
    echo "$smoke_json" > "$vdir/smoke-static.json"
    remote_run "$SERVER_TARGET" rm -f /tmp/compat-smoke-guest.sh || true
    local hard_gate_ok
    hard_gate_ok=$(printf '%s' "$smoke_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("false"); sys.exit()
checks = {c["name"]: c["pass"] for c in d.get("checks", [])}
hard = ["uname-gate", "verify-bpf", "skyline-speederd-start", "capabilities-hard-gate", "cc-register"]
print("true" if all(checks.get(name) for name in hard) else "false")
')
    local caps_json
    caps_json=$(printf '%s' "$smoke_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("{}"); sys.exit()
for c in d.get("checks", []):
    if c["name"] == "capabilities":
        print(c.get("detail") or "{}")
        sys.exit()
print("{}")
')
    patch_state "$version" "{\"capabilities\":$caps_json}"
    if [ "$hard_gate_ok" = true ]; then
        pass_stage "$version" smoke-static "$smoke_json"
    else
        fail_stage "$version" smoke-static "one or more hard-gate checks failed, see smoke-static.json/.log: $smoke_json"
        [ "$PAUSE_ON_FAILURE" = 1 ] || teardown_vms
        return 1
    fi

    # --- data-plane smoke (v4 always; v6 skip if matrix_lib lacks support) ---
    remote_run "$SERVER_TARGET" sudo systemctl start skyline-speederd.service >/dev/null 2>&1 || true
    local smoke_manifest="research/experiments/manifests/kernel-compat-smoke.toml"
    [ "$ACCEL" = tcg ] && smoke_manifest="research/experiments/manifests/kernel-compat-smoke-tcg.toml"
    local matrix_out="$vdir/matrix"
    rm -rf "$matrix_out" "$matrix_out-analysis"
    if SKYLINE_TC="$SKYLINE_TC_BIN" PATH="$PATH:/usr/sbin:/sbin" "$PYTHON" research/experiments/run_matrix.py \
        "$smoke_manifest" "$matrix_out" --execute --keep-going \
        > "$vdir/data-plane-smoke.log" 2>&1; then
        : # exit 0 -- fall through to analysis regardless, `--keep-going`
          # means individual case failures don't fail the run_matrix.py
          # invocation itself
    fi
    if "$PYTHON" research/experiments/analyze_results.py "$matrix_out" "$matrix_out-analysis" \
        >> "$vdir/data-plane-smoke.log" 2>&1; then
        local v4_ok v6_status
        v4_ok=$("$PYTHON" -c "
import csv
rows = list(csv.DictReader(open('$matrix_out-analysis/runs.csv')))
v4 = [r for r in rows if r['address_family'] == 'v4']
ok = bool(v4) and all(
    r['valid'] == 'True' and r['retransmit_capture_false_positives'] in ('0', '')
    for r in v4
)
print('true' if ok else 'false')
")
        if [ "$v4_ok" = true ]; then
            pass_stage "$version" smoke-v4
        else
            fail_stage "$version" smoke-v4 "see $matrix_out-analysis/runs.csv"
        fi
        v6_status=$("$PYTHON" -c "
import csv
rows = list(csv.DictReader(open('$matrix_out-analysis/runs.csv')))
v6 = [r for r in rows if r['address_family'] == 'v6']
if not v6:
    print('skip:no-v6-cases-in-manifest')
else:
    ok = all(
        r['valid'] == 'True' and r['retransmit_capture_false_positives'] in ('0', '')
        for r in v6
    )
    print('pass' if ok else 'fail')
")
        case "$v6_status" in
            pass) pass_stage "$version" smoke-v6 ;;
            skip:*) skip_stage "$version" smoke-v6 "${v6_status#skip:}" ;;
            *) fail_stage "$version" smoke-v6 "see $matrix_out-analysis/runs.csv" ;;
        esac
    else
        fail_stage "$version" smoke-v4 "analyze_results.py failed, see data-plane-smoke.log"
        fail_stage "$version" smoke-v6 "analyze_results.py failed, see data-plane-smoke.log"
    fi

    # --- teardown ---
    local any_failed=0
    for stage in overlay boot kernel-install uname-gate bpf-compile skyline-deploy smoke-static smoke-v4; do
        stage_ok "$version" "$stage" || any_failed=1
    done
    if [ "$any_failed" = 1 ] && [ "$PAUSE_ON_FAILURE" = 1 ]; then
        log "$version: leaving VM pair up for inspection (--pause-on-failure); SSH via $SERVER_TARGET"
        skip_stage "$version" teardown "left running, --pause-on-failure"
    else
        teardown_vms
        pass_stage "$version" teardown
    fi

    if [ "$any_failed" = 0 ]; then
        patch_state "$version" '{"overall":"pass"}'
        return 0
    else
        patch_state "$version" '{"overall":"fail"}'
        return 1
    fi
}

do_test() {
    local failures=0
    for version in "${VERSIONS[@]}"; do
        if ! do_test_one "$version"; then
            failures=$((failures + 1))
            [ "$KEEP_GOING" = 1 ] || { log "stopping after $version's test failure (--no-keep-going)"; break; }
        fi
    done
    log "test phase: ${#VERSIONS[@]} version(s), $failures failure(s)"
    [ "$failures" -eq 0 ]
}

# -------------------------------------------------------------- report ----

do_report() {
    local out_dir="$CAMPAIGN_ROOT/report"
    rm -rf "$out_dir"
    "$PYTHON" research/experiments/render_kernel_compat_report.py "$CAMPAIGN_ROOT" "$out_dir"
    log "report: $out_dir/report.md"
    echo "Archive with: cp $out_dir/report.md research/reports/kernel-compat-\$(date +%F).md"
}

# --------------------------------------------------------------- main -----

overall_rc=0
# do_build/do_test return nonzero when any version failed -- under set -e, a
# bare `do_test; do_report` would abort AT do_test's own nonzero return,
# before do_report ever runs, which defeats the point of a report on a
# partially-failed campaign (arguably the most important time to have one).
# `|| overall_rc=$?` catches it without suppressing the final exit code.
case "$PHASE" in
    plan) do_plan ;;
    build) do_plan; do_build || overall_rc=$? ;;
    test) do_test || overall_rc=$?; do_report ;;
    report) do_report ;;
    all) do_plan; do_build || overall_rc=$?; do_test || overall_rc=$?; do_report ;;
    *) echo "Unknown phase: $PHASE" >&2; exit 2 ;;
esac
exit "$overall_rc"
