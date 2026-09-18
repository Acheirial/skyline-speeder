#!/usr/bin/env bash
set -euo pipefail

TARGET=${SKYLINE_SERVER_SSH:-skyline@127.0.0.1:2222}
CONFIRM=${1:-}
KNOWN_HOSTS=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}

if [ "$CONFIRM" != --confirm-install ]; then
    cat <<EOF
This builds Skyline Speeder on the host, copies it only to the server guest at $TARGET,
and replaces the system paths listed by infra/install-prebuilt-guest.sh.
The client guest is not modified. Local and remote staging directories are
preserved for audit and rollback.

Re-run with: $0 --confirm-install
EOF
    exit 2
fi

host=${TARGET%:*}
port=${TARGET##*:}
if [ "$host" = "$TARGET" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
    host=$TARGET
    port=22
fi

make bpf
cargo build --workspace --release

BUILD_ID=$(date --utc +%Y%m%dT%H%M%SZ)-$$
STAGING_ROOT="build/guest-staging/skyline-$BUILD_ID"
REMOTE_ROOT="/tmp/skyline-$BUILD_ID"
if [ -e "$STAGING_ROOT" ]; then
    echo "Refusing to overwrite local staging root: $STAGING_ROOT" >&2
    exit 1
fi
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
    test ! -e "$REMOTE_ROOT"; then
    echo "Refusing to overwrite remote staging root: $host:$REMOTE_ROOT" >&2
    exit 1
fi

install -d "$STAGING_ROOT/bin" "$STAGING_ROOT/bpf" "$STAGING_ROOT/infra" \
    "$STAGING_ROOT/config" "$STAGING_ROOT/packaging"
install -m 0755 target/release/skyline-speederd "$STAGING_ROOT/bin/skyline-speederd"
install -m 0755 target/release/ssctl "$STAGING_ROOT/bin/ssctl"
install -m 0644 build/bpf/*.bpf.o "$STAGING_ROOT/bpf/"
install -m 0755 infra/apply-guest-profile.sh infra/collect-guest-metrics.sh \
    infra/snapshot-skyline-events.sh infra/run-in-skyline-cgroup.sh \
    infra/install-prebuilt-guest.sh \
    "$STAGING_ROOT/infra/"
install -m 0644 config/speeder-guest.toml "$STAGING_ROOT/config/speeder.toml"
install -m 0644 packaging/skyline-speederd.service "$STAGING_ROOT/packaging/skyline-speederd.service"
while IFS= read -r -d '' relative; do
    digest=$(sha256sum -- "$STAGING_ROOT/$relative" | awk '{print $1}')
    printf '%s  %s/%s\n' "$digest" "$REMOTE_ROOT" "$relative"
done < <(
    find "$STAGING_ROOT" -type f ! -name SHA256SUMS -printf '%P\0' | sort -z
) > "$STAGING_ROOT/SHA256SUMS"

scp -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" -P "$port" -r -- \
    "$STAGING_ROOT" "$host:$REMOTE_ROOT"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
    sudo "$REMOTE_ROOT/infra/install-prebuilt-guest.sh" \
    "$REMOTE_ROOT" --confirm-install
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
    sha256sum -c "$REMOTE_ROOT/SHA256SUMS"

echo "Local staging preserved at $(realpath -- "$STAGING_ROOT")"
echo "Remote staging preserved at $host:$REMOTE_ROOT"
