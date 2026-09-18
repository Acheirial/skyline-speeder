#!/usr/bin/env bash
set -euo pipefail

SSH_PUBLIC_KEY_FILE=${1:-}
OUTPUT_DIR=${2:-build/images}

if [ -z "$SSH_PUBLIC_KEY_FILE" ] || [ ! -f "$SSH_PUBLIC_KEY_FILE" ]; then
    echo "Usage: $0 SSH_PUBLIC_KEY_FILE [OUTPUT_DIR]" >&2
    exit 2
fi
if ! command -v cloud-localds >/dev/null 2>&1; then
    echo "cloud-localds is required" >&2
    exit 1
fi

SERVER_SEED="$OUTPUT_DIR/server-seed.img"
CLIENT_SEED="$OUTPUT_DIR/client-seed.img"
for target in "$SERVER_SEED" "$CLIENT_SEED"; do
    if [ -e "$target" ]; then
        echo "Refusing to overwrite existing cloud-init seed: $target" >&2
        exit 1
    fi
done

mkdir -p "$OUTPUT_DIR"
SSH_PUBLIC_KEY=$(<"$SSH_PUBLIC_KEY_FILE")
USER_DATA=$(mktemp)
if [ "${SKYLINE_KEEP_CLOUD_INIT_TEMP:-0}" = 1 ]; then
    echo "Keeping rendered cloud-init user-data at $USER_DATA"
else
    trap 'rm -f -- "$USER_DATA"' EXIT
fi
sed "s|__SSH_PUBLIC_KEY__|$SSH_PUBLIC_KEY|" infra/cloud-init/user-data.template > "$USER_DATA"

cloud-localds --network-config=infra/cloud-init/network-server.yaml \
    "$SERVER_SEED" "$USER_DATA" infra/cloud-init/meta-data-server
cloud-localds --network-config=infra/cloud-init/network-client.yaml \
    "$CLIENT_SEED" "$USER_DATA" infra/cloud-init/meta-data-client
echo "Cloud-init seed images written to $OUTPUT_DIR"
