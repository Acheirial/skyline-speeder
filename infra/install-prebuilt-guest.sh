#!/usr/bin/env bash
set -euo pipefail

STAGING_ROOT=${1:-}
CONFIRM=${2:-}

if [ -z "$STAGING_ROOT" ] || [ ! -d "$STAGING_ROOT" ]; then
    echo "Usage: $0 STAGING_ROOT [--confirm-install]" >&2
    exit 2
fi
STAGING_ROOT=$(realpath -- "$STAGING_ROOT")
if [ "$CONFIRM" != --confirm-install ]; then
    cat <<EOF
Prebuilt Skyline Speeder guest installation plan:
  staging root: $STAGING_ROOT
  replace: /usr/local/sbin/skyline-speederd, /usr/local/bin/ssctl
  replace: /opt/skyline-speeder/bpf/*.bpf.o, /opt/skyline-speeder/infra/*.sh
  replace: /etc/systemd/system/skyline-speederd.service
  preserve: existing /etc/skyline-speeder/speeder.toml
  rollback: boot the parent qcow2 overlay or reinstall the previous artifacts

Re-run with --confirm-install.
EOF
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Installation requires root" >&2
    exit 1
fi
for path in \
    bin/skyline-speederd bin/ssctl config/speeder.toml packaging/skyline-speederd.service \
    infra/apply-guest-profile.sh infra/collect-guest-metrics.sh \
    infra/snapshot-skyline-events.sh infra/run-in-skyline-cgroup.sh; do
    if [ ! -f "$STAGING_ROOT/$path" ]; then
        echo "Missing staging artifact: $STAGING_ROOT/$path" >&2
        exit 1
    fi
done
if ! compgen -G "$STAGING_ROOT/bpf/*.bpf.o" >/dev/null; then
    echo "No BPF objects found below $STAGING_ROOT/bpf" >&2
    exit 1
fi

install -d /opt/skyline-speeder/bpf /opt/skyline-speeder/infra /etc/skyline-speeder /run/skyline-speeder /sys/fs/bpf/skyline-speeder
install -m 0755 "$STAGING_ROOT/bin/skyline-speederd" /usr/local/sbin/skyline-speederd
install -m 0755 "$STAGING_ROOT/bin/ssctl" /usr/local/bin/ssctl
install -m 0644 "$STAGING_ROOT"/bpf/*.bpf.o /opt/skyline-speeder/bpf/
install -m 0755 "$STAGING_ROOT"/infra/*.sh /opt/skyline-speeder/infra/
install -m 0644 "$STAGING_ROOT/packaging/skyline-speederd.service" \
    /etc/systemd/system/skyline-speederd.service
if [ ! -e /etc/skyline-speeder/speeder.toml ]; then
    install -m 0644 "$STAGING_ROOT/config/speeder.toml" /etc/skyline-speeder/speeder.toml
fi
mkdir -p /sys/fs/cgroup/skyline-speeder
systemctl daemon-reload
systemctl enable skyline-speederd.service
echo "Installed prebuilt Skyline Speeder artifacts; start skyline-speederd.service explicitly after validation."
