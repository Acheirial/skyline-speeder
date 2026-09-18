#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [BASE_IMAGE] [OUTPUT_DIR]

Create independent server and client qcow2 overlays.
EOF
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
    usage
    exit 0
fi
if [ "$#" -gt 2 ] || [[ "${1:-}" = -* ]] || [[ "${2:-}" = -* ]]; then
    usage >&2
    exit 2
fi

BASE_IMAGE=${1:-build/images/noble-server-cloudimg-amd64.img}
OUTPUT_DIR=${2:-build/images}
SERVER_IMAGE="$OUTPUT_DIR/server.qcow2"
CLIENT_IMAGE="$OUTPUT_DIR/client.qcow2"
DISK_GIB=${SKYLINE_VM_DISK_GIB:-12}

if [ ! -f "$BASE_IMAGE" ]; then
    echo "Base image does not exist: $BASE_IMAGE" >&2
    exit 1
fi
if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img is required" >&2
    exit 1
fi
for target in "$SERVER_IMAGE" "$CLIENT_IMAGE"; do
    if [ -e "$target" ]; then
        echo "Refusing to overwrite existing overlay: $target" >&2
        exit 1
    fi
done

mkdir -p -- "$OUTPUT_DIR"
BASE_ABSOLUTE=$(realpath -- "$BASE_IMAGE")
qemu-img create -f qcow2 -F qcow2 -b "$BASE_ABSOLUTE" -- "$SERVER_IMAGE"
qemu-img create -f qcow2 -F qcow2 -b "$BASE_ABSOLUTE" -- "$CLIENT_IMAGE"
qemu-img resize -- "$SERVER_IMAGE" "${DISK_GIB}G"
qemu-img resize -- "$CLIENT_IMAGE" "${DISK_GIB}G"
echo "Created ${DISK_GIB} GiB server/client qcow2 overlays in $OUTPUT_DIR"
