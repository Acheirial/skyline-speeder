#!/usr/bin/env bash
set -euo pipefail

SERVER_BASE=${1:-}
CLIENT_BASE=${2:-}
OUTPUT_DIR=${3:-}

if [ -z "$SERVER_BASE" ] || [ -z "$CLIENT_BASE" ] || [ -z "$OUTPUT_DIR" ]; then
    cat >&2 <<EOF
Usage: $0 SERVER_BASE CLIENT_BASE OUTPUT_DIR

Create versioned server/client child overlays without modifying either parent.
EOF
    exit 2
fi
for base in "$SERVER_BASE" "$CLIENT_BASE"; do
    if [ ! -f "$base" ]; then
        echo "Base image does not exist: $base" >&2
        exit 1
    fi
done
SERVER_IMAGE="$OUTPUT_DIR/server.qcow2"
CLIENT_IMAGE="$OUTPUT_DIR/client.qcow2"
DISK_GIB=${SKYLINE_VM_DISK_GIB:-12}
for target in "$SERVER_IMAGE" "$CLIENT_IMAGE"; do
    if [ -e "$target" ]; then
        echo "Refusing to overwrite existing child overlay: $target" >&2
        exit 1
    fi
done
mkdir -p -- "$OUTPUT_DIR"
qemu-img create -f qcow2 -F qcow2 -b "$(realpath -- "$SERVER_BASE")" \
    -- "$SERVER_IMAGE"
qemu-img create -f qcow2 -F qcow2 -b "$(realpath -- "$CLIENT_BASE")" \
    -- "$CLIENT_IMAGE"
qemu-img resize -- "$SERVER_IMAGE" "${DISK_GIB}G"
qemu-img resize -- "$CLIENT_IMAGE" "${DISK_GIB}G"
qemu-img info --backing-chain --output=json "$SERVER_IMAGE"
qemu-img info --backing-chain --output=json "$CLIENT_IMAGE"
