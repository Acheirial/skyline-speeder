#!/usr/bin/env bash
set -euo pipefail

VERSION=6.18.0
SHA256=6ba520e1975e4c50dc931eeae91ea37c198b8a173744885f8895b84325f9d456
URL=https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-${VERSION}.tar.xz
BUILD_ROOT=${SKYLINE_IPROUTE2_BUILD_ROOT:-build/iproute2}
ARCHIVE="$BUILD_ROOT/iproute2-${VERSION}.tar.xz"
SOURCE_DIR="$BUILD_ROOT/iproute2-${VERSION}"
OUTPUT=${SKYLINE_TC_OUTPUT:-build/tools/tc-iproute2-${VERSION}}

usage() {
    cat <<EOF
Usage: $0 [--resume]

Build a repository-local iproute2 ${VERSION} tc binary with NetEm seed support.
The default mode refuses existing paths. --resume reuses a verified archive and
an already extracted source tree after an interrupted build; it never overwrites
the final output binary.
EOF
}

RESUME=0
case "${1:-}" in
    "") ;;
    -h|--help) usage; exit 0 ;;
    --resume) RESUME=1 ;;
    *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

for command in curl sha256sum tar make gcc pkg-config; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Missing build command: $command" >&2
        exit 1
    fi
done
if [ -e "$OUTPUT" ] || [ -e "$ARCHIVE.part" ]; then
    echo "Refusing to overwrite existing path: $OUTPUT or $ARCHIVE.part" >&2
    exit 1
fi
if [ "$RESUME" -eq 0 ] && { [ -e "$ARCHIVE" ] || [ -e "$SOURCE_DIR" ]; }; then
    echo "Archive or source tree already exists; inspect it and use --resume." >&2
    exit 1
fi

mkdir -p -- "$BUILD_ROOT" "$(dirname -- "$OUTPUT")"
if [ ! -e "$ARCHIVE" ]; then
    curl -L --fail --show-error --output "$ARCHIVE.part" "$URL"
    printf '%s  %s\n' "$SHA256" "$ARCHIVE.part" | sha256sum --check --status
    mv -- "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | sha256sum --check --status
if [ ! -d "$SOURCE_DIR" ]; then
    tar -C "$BUILD_ROOT" -xf "$ARCHIVE"
fi
make -C "$SOURCE_DIR" -j"$(nproc)"
install -m 0755 "$SOURCE_DIR/tc/tc" "$OUTPUT"

NETEM_HELP=$("$OUTPUT" qdisc add dev lo root netem help 2>&1 || true)
if ! grep -qw seed <<<"$NETEM_HELP"; then
    echo "Built tc does not advertise NetEm seed support" >&2
    exit 1
fi
echo "Built $OUTPUT"
echo "Use it with: SKYLINE_TC=$OUTPUT sudo -E infra/configure-path.sh ..."
