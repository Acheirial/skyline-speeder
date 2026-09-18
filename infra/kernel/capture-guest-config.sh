#!/usr/bin/env bash
set -euo pipefail

TARGET=${SKYLINE_SERVER_SSH:-skyline@127.0.0.1:2222}
OUTPUT=${1:-build/kernel/config-guest-bootstrap}
KNOWN_HOSTS=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}

host=${TARGET%:*}
port=${TARGET##*:}
if [ "$host" = "$TARGET" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
    host=$TARGET
    port=22
fi
if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite guest config: $OUTPUT" >&2
    exit 1
fi
mkdir -p -- "$(dirname -- "$OUTPUT")"
temporary="${OUTPUT}.part"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
    'cat /boot/config-$(uname -r)' > "$temporary"
if ! grep -q '^CONFIG_BPF=' "$temporary"; then
    echo "Captured file does not look like a Linux kernel config" >&2
    exit 1
fi
mv -- "$temporary" "$OUTPUT"
sha256sum -- "$OUTPUT"
echo "Use SKYLINE_KERNEL_BASE_CONFIG=$OUTPUT when running infra/kernel/build.sh"
