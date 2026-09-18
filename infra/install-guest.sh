#!/usr/bin/env bash
set -euo pipefail

CONFIRM=${1:-}
REPOSITORY_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$CONFIRM" != --confirm-install ]; then
    cat <<EOF
This installs or replaces:
  /usr/local/sbin/skyline-speederd
  /usr/local/bin/ssctl
  /opt/skyline-speeder/bpf/*.bpf.o
  /opt/skyline-speeder/infra/*.sh
  /etc/systemd/system/skyline-speederd.service
  /etc/systemd/system/skyline-speeder-enable.service
It creates /etc/skyline-speeder/speeder.toml only when that file does not already exist.

Re-run with: $0 --confirm-install
EOF
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Installation requires root." >&2
    exit 1
fi

cd "$REPOSITORY_ROOT"
make bpf
cargo build --workspace --release

install -d /opt/skyline-speeder/bpf /opt/skyline-speeder/infra /etc/skyline-speeder /run/skyline-speeder /sys/fs/bpf/skyline-speeder
install -m 0755 target/release/skyline-speederd /usr/local/sbin/skyline-speederd
install -m 0755 target/release/ssctl /usr/local/bin/ssctl
install -m 0644 build/bpf/*.bpf.o /opt/skyline-speeder/bpf/
install -m 0755 infra/apply-guest-profile.sh infra/collect-guest-metrics.sh \
    infra/snapshot-skyline-events.sh infra/run-in-skyline-cgroup.sh \
    infra/boot-enable.sh infra/boot-disable.sh /opt/skyline-speeder/infra/
install -m 0644 packaging/skyline-speederd.service /etc/systemd/system/skyline-speederd.service
install -m 0644 packaging/skyline-speeder-enable.service \
    /etc/systemd/system/skyline-speeder-enable.service
if [ ! -e /etc/skyline-speeder/speeder.toml ]; then
    install -m 0644 config/speeder-guest.toml /etc/skyline-speeder/speeder.toml
fi
mkdir -p /sys/fs/cgroup/skyline-speeder
systemctl daemon-reload
systemctl enable skyline-speederd.service
# skyline-speeder-enable.service is installed but NOT enabled here: attaching the
# struct_ops changes the congestion control for every new connection on the box,
# which is an operator decision, not an install-time one. install.sh (the
# one-click path) enables it after confirming the runtime prerequisites.
echo "Installed Skyline Speeder."
echo "Review /etc/skyline-speeder/speeder.toml (especially runtime.tc_interface),"
echo "then start skyline-speederd.service, or run ./install.sh for the guided path."
