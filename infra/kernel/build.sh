#!/usr/bin/env bash
set -euo pipefail

VERSION=${SKYLINE_KERNEL_VERSION:-6.18.40}
ARCHIVE=${SKYLINE_KERNEL_ARCHIVE:-build/kernel/linux-${VERSION}.tar.xz}
SOURCE_DIR=${SKYLINE_KERNEL_SOURCE_DIR:-build/kernel/linux-${VERSION}}
OUTPUT_DIR=${SKYLINE_KERNEL_OUTPUT_DIR:-build/kernel/out-${VERSION}}
BASE_CONFIG=${SKYLINE_KERNEL_BASE_CONFIG:-/boot/config-$(uname -r)}
JOBS=${SKYLINE_KERNEL_JOBS:-$(getconf _NPROCESSORS_ONLN)}
RESUME=${SKYLINE_KERNEL_RESUME:-0}

for command_name in make tar xz gcc bc bison flex openssl pahole \
    dpkg-buildpackage fakeroot; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing kernel build command: $command_name" >&2
        exit 1
    }
done
if [ ! -f "$ARCHIVE" ]; then
    echo "Kernel archive is missing: $ARCHIVE" >&2
    exit 1
fi
if [ ! -f "$BASE_CONFIG" ]; then
    echo "Base kernel config is missing: $BASE_CONFIG" >&2
    exit 1
fi
if [ "$RESUME" = 1 ]; then
    if [ ! -d "$SOURCE_DIR" ] || [ ! -f "$OUTPUT_DIR/.config" ]; then
        echo "Resume requires the existing source tree and output .config." >&2
        exit 1
    fi
elif [ -e "$SOURCE_DIR" ] || [ -e "$OUTPUT_DIR" ]; then
    echo "Refusing to overwrite an existing kernel source/output directory." >&2
    echo "  source: $SOURCE_DIR" >&2
    echo "  output: $OUTPUT_DIR" >&2
    echo "Set SKYLINE_KERNEL_RESUME=1 only after reviewing these paths." >&2
    exit 1
else
    mkdir -p "$(dirname "$SOURCE_DIR")" "$OUTPUT_DIR"
    tar -xf "$ARCHIVE" -C "$(dirname "$SOURCE_DIR")"
    cp "$BASE_CONFIG" "$OUTPUT_DIR/.config"
fi

scripts_config="$SOURCE_DIR/scripts/config"
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable BPF
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable BPF_SYSCALL
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable BPF_JIT
# DEBUG_INFO_BTF is itself a member of a debug-info `choice` group whose
# other members (DEBUG_INFO_NONE, DEBUG_INFO_REDUCED, ...) are mutually
# exclusive with it -- `--enable` on a choice member does not clear a
# sibling that the base config already set to `y`. A base config coming
# from a distro that defaults to no debug info at all (DEBUG_INFO_NONE=y,
# common on Ubuntu) needs that sibling explicitly disabled first, or
# olddefconfig silently keeps DEBUG_INFO_NONE and reverts DEBUG_INFO_BTF
# with no error.
"$scripts_config" --file "$OUTPUT_DIR/.config" --disable DEBUG_INFO_NONE
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable DEBUG_INFO
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable DEBUG_INFO_BTF
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable FTRACE
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable FUNCTION_TRACER
"$scripts_config" --file "$OUTPUT_DIR/.config" --enable TCP_CONG_CUBIC
"$scripts_config" --file "$OUTPUT_DIR/.config" --module TCP_CONG_BBR
"$scripts_config" --file "$OUTPUT_DIR/.config" --module NET_SCH_FQ
# Ubuntu's guest config references Canonical packaging certificates that are
# not part of a clean upstream kernel tarball. Keep module signing's generated
# development key, but do not depend on distro-only trust/revocation files.
"$scripts_config" --file "$OUTPUT_DIR/.config" --set-str SYSTEM_TRUSTED_KEYS ""
"$scripts_config" --file "$OUTPUT_DIR/.config" --set-str SYSTEM_REVOCATION_KEYS ""

REALOUT=$(realpath "$OUTPUT_DIR")

# Optional, version-specific scripts/config overrides discovered while
# debugging a specific kernel's build -- deliberately not auto-applied from
# any built-in guess. Applied BEFORE the one olddefconfig run below (and
# before the informational listnewconfig snapshot), not after: a symbol
# forced above by this script can itself depend on something olddefconfig
# only resolves once every override -- including a version-specific one
# from this file -- is already in place. Applying it afterward would mean
# a retry with a newly-added override still fails the same way the first
# attempt did, since olddefconfig would never re-run against it.
if [ -n "${SKYLINE_KERNEL_EXTRA_CONFIG:-}" ]; then
    if [ ! -f "$SKYLINE_KERNEL_EXTRA_CONFIG" ]; then
        echo "SKYLINE_KERNEL_EXTRA_CONFIG is set but not a file: $SKYLINE_KERNEL_EXTRA_CONFIG" >&2
        exit 1
    fi
    # One scripts/config invocation's worth of flags per line, e.g.
    # "--enable SOME_SYMBOL" or "--set-str OTHER_SYMBOL value" -- blank
    # lines and #-comments skipped.
    while IFS= read -r extra_config_line || [ -n "$extra_config_line" ]; do
        [ -z "$extra_config_line" ] && continue
        case "$extra_config_line" in \#*) continue ;; esac
        # Intentional word-splitting: each line is meant to become several
        # argv words for scripts/config.
        # shellcheck disable=SC2086
        "$scripts_config" --file "$OUTPUT_DIR/.config" $extra_config_line
    done < "$SKYLINE_KERNEL_EXTRA_CONFIG"
fi

# What would olddefconfig pick for symbols the base config doesn't have an
# opinion on -- the only non-guesswork way to see this, since olddefconfig
# itself never explains a choice. Informational: newly-introduced symbols
# taking a default value is normal kernel evolution, not by itself a
# problem; it becomes one only if a symbol from the required list below
# turns out to be among them with an unwanted default, which the assertion
# step (not this listing) is what actually catches.
make -C "$SOURCE_DIR" O="$REALOUT" listnewconfig \
    > "build/kernel/listnewconfig-${VERSION}.txt" 2>&1 || true
cp "$OUTPUT_DIR/.config" "build/kernel/config-${VERSION}.pre-olddefconfig"

make -C "$SOURCE_DIR" O="$REALOUT" olddefconfig

# Full diff archived for human review, never as a pass/fail gate -- most
# lines are unremarkable version-to-version Kconfig churn, and treating
# every line as a required match would make this assertion step reject
# kernels for reasons that have nothing to do with what Skyline Speeder actually needs.
"$SOURCE_DIR/scripts/diffconfig" \
    "build/kernel/config-${VERSION}.pre-olddefconfig" "$OUTPUT_DIR/.config" \
    > "build/kernel/diffconfig-${VERSION}.txt" 2>&1 || true

# Post-olddefconfig assertion: olddefconfig resolves an unmet dependency by
# silently reverting the symbol that depends on it, even one this script
# just forced above -- with no error, no log line, nothing but a
# differently-behaving kernel. This checks that the options this script
# forces, plus a short list Skyline Speeder depends on at runtime but has never had to
# force (the base Ubuntu guest config already carries them), still hold
# their required value after olddefconfig ran. A symbol not appearing in
# the resulting .config at all is treated as a WARNING, not a failure --
# Kconfig symbols do get renamed/restructured across major versions (6.1
# through 7.1 span here), and guessing that away would be exactly the kind
# of unverified assumption this project avoids; a *wrong value* on a
# symbol that IS present is the actual "olddefconfig quietly reverted our
# forced setting" failure mode this exists to catch, and that one is fatal.
assert_config() {
    local symbol=$1 expected=$2 line actual
    line=$(grep -E "^CONFIG_${symbol}(=| is not set$)" "$REALOUT/.config" || true)
    if [ -z "$line" ]; then
        echo "WARNING: CONFIG_${symbol} not present in ${VERSION}'s .config (possibly renamed/restructured for this kernel line; needs human review, not treated as fatal)" >&2
        return 0
    fi
    case "$line" in
        "# CONFIG_${symbol} is not set") actual=n ;;
        "CONFIG_${symbol}="*) actual=${line#CONFIG_${symbol}=} ;;
    esac
    # "avail" (used for the never-explicitly-forced group below) means "y or
    # m both satisfy what Skyline Speeder actually needs (the functionality is usable
    # either compiled in or as a loadable module)" -- built-in is a strict
    # superset of module for every one of those symbols' purposes here, so
    # treating "kernel decided to build it in instead of as a module" as a
    # failure would be asserting a preference nobody has, not catching a
    # real regression: NET_SCH_FQ_CODEL has been observed coming out of
    # olddefconfig as `y` instead of `m` with no dependency issue at all
    # between two kernel patch releases -- just a Kconfig default that
    # shifted.
    if [ "$expected" = avail ]; then
        if [ "$actual" = y ] || [ "$actual" = m ]; then
            return 0
        fi
        echo "FATAL: CONFIG_${symbol}=${actual} after olddefconfig, expected y or m (some usable form) -- see build/kernel/diffconfig-${VERSION}.txt" >&2
        return 1
    fi
    if [ "$actual" != "$expected" ]; then
        echo "FATAL: CONFIG_${symbol}=${actual} after olddefconfig, expected ${expected} -- olddefconfig reverted a forced/required setting for an unmet-dependency reason; see build/kernel/diffconfig-${VERSION}.txt" >&2
        return 1
    fi
}

config_failures=0
# Forced above in this script with a SPECIFIC form (--enable vs --module) --
# must hold that exact form, not just "enabled somehow": TCP_CONG_CUBIC is
# deliberately built-in (available from early boot as the fallback CC,
# not dependent on module loading succeeding), TCP_CONG_BBR/NET_SCH_FQ are
# deliberately modules (see the comments above where they're forced) --
# unlike the "avail" group below, a form change here IS the "olddefconfig
# silently overrode our choice" bug this whole check exists to catch.
for pair in "BPF:y" "BPF_SYSCALL:y" "BPF_JIT:y" "DEBUG_INFO_BTF:y" \
    "FTRACE:y" "FUNCTION_TRACER:y" "TCP_CONG_CUBIC:y" "TCP_CONG_BBR:m" \
    "NET_SCH_FQ:m"; do
    assert_config "${pair%%:*}" "${pair##*:}" || config_failures=$((config_failures + 1))
done
# Never forced, but Skyline Speeder's control plane/BPF programs/test infra depend on
# these being AVAILABLE in some usable form at runtime (cgroup v2 BPF hooks,
# TC clsact for skyline_tc.bpf.c, NetEm/HTB/fq_codel for
# infra/configure-path.sh, veth/bridge/netns for infra/topology.sh, IPv6 for
# the dual-stack test bed) -- nothing here dictates built-in vs module, only
# "not compiled out entirely" (see assert_config's "avail" handling above).
for symbol in CGROUP_BPF CGROUPS NET_CLS_ACT NET_SCH_NETEM \
    NET_SCH_HTB NET_SCH_FQ_CODEL IPV6 VETH BRIDGE NAMESPACES NET_NS; do
    assert_config "$symbol" avail || config_failures=$((config_failures + 1))
done
if [ "$config_failures" -gt 0 ]; then
    echo "$config_failures required config symbol(s) did not hold their expected value after olddefconfig; refusing to build ${VERSION}. Look at diffconfig/listnewconfig above, write version-specific overrides into a file, and re-run with SKYLINE_KERNEL_EXTRA_CONFIG=<that file> SKYLINE_KERNEL_RESUME=1 -- do not guess." >&2
    exit 1
fi

make -C "$SOURCE_DIR" O="$REALOUT" -j"$JOBS" bindeb-pkg
cp "$OUTPUT_DIR/.config" "build/kernel/config-${VERSION}"
sha256sum "$OUTPUT_DIR/vmlinux" > "build/kernel/vmlinux-${VERSION}.sha256"
echo "Kernel packages were written beneath build/kernel/."
