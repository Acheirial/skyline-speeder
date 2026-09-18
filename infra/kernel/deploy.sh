#!/usr/bin/env bash
set -euo pipefail

VERSION=${SKYLINE_KERNEL_VERSION:-6.18.40}
PACKAGE_DIR=${1:-build/kernel}
CONFIRM=${2:-}
SERVER_TARGET=${SKYLINE_SERVER_SSH:-skyline@127.0.0.1:2222}
CLIENT_TARGET=${SKYLINE_CLIENT_SSH:-skyline@127.0.0.1:2223}
REMOTE_DIR="/tmp/skyline-kernel-${VERSION}"
KNOWN_HOSTS=${SKYLINE_SSH_KNOWN_HOSTS:-build/run/known_hosts}

parse_target() {
    local value=$1
    local host
    local port
    host=${value%:*}
    port=${value##*:}
    if [ "$host" = "$value" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        host=$value
        port=22
    fi
    printf '%s\n%s\n' "$host" "$port"
}

mapfile -t PACKAGES < <(
    find "$PACKAGE_DIR" -maxdepth 1 -type f \
        \( -name "linux-image-*${VERSION}*.deb" \
        -o -name "linux-headers-*${VERSION}*.deb" \
        -o -name "linux-libc-dev_*${VERSION}*.deb" \) \
        ! -name "linux-image-*-dbg_*.deb" \
        -print | sort
)

if [ "${#PACKAGES[@]}" -lt 2 ]; then
    echo "Expected Linux ${VERSION} image and header packages in $PACKAGE_DIR" >&2
    exit 1
fi

TOTAL_BYTES=$(du -cb -- "${PACKAGES[@]}" | awk 'END {print $1}')
printf 'Kernel deployment plan:\n'
printf '  version: %s\n' "$VERSION"
printf '  package root: %s\n' "$(realpath "$PACKAGE_DIR")"
printf '  package count: %s\n' "${#PACKAGES[@]}"
printf '  total bytes: %s\n' "$TOTAL_BYTES"
printf '  remote targets: %s, %s\n' "$SERVER_TARGET" "$CLIENT_TARGET"
printf '  remote staging directory: %s\n' "$REMOTE_DIR"
printf '  effect: installs kernel packages, pins GRUB default to %s; reboot remains manual\n' "$VERSION"
printf '%s\n' '  rollback: sudo grub-set-default to a different menuentry, or restore /etc/default/grub.skyline-orig + update-grub'

if [ "$CONFIRM" != --confirm-install-kernel ]; then
    echo "Re-run with: $0 $PACKAGE_DIR --confirm-install-kernel"
    exit 2
fi

for target in "$SERVER_TARGET" "$CLIENT_TARGET"; do
    mapfile -t parsed < <(parse_target "$target")
    host=${parsed[0]}
    port=${parsed[1]}
    if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        test ! -e "$REMOTE_DIR"; then
        echo "Refusing to overwrite remote staging directory: $host:$REMOTE_DIR" >&2
        exit 1
    fi
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        mkdir -- "$REMOTE_DIR"
    scp -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -P "$port" -- \
        "${PACKAGES[@]}" "$host:$REMOTE_DIR/"
    # --allow-downgrades: the compat matrix deliberately spans versions both
    # above and below the base image's own kernel package (e.g. 6.1.180/
    # 6.6.148 vs a noble base around 6.8) -- linux-libc-dev is shared across
    # all kernel versions on a system, so installing an older target version
    # downgrades it, which apt -y refuses by default.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        sudo apt-get install -y --allow-downgrades "$REMOTE_DIR"/*.deb
    # Ubuntu's /usr/sbin/bpftool wrapper only searches for tools matching the
    # running distro kernel. Preserve an already installed real binary for the
    # custom upstream kernel before rebooting into it.
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        'actual=$(find /usr/lib -path "/usr/lib/linux-tools-*/bpftool" -type f | sort -V | tail -1); test -x "$actual"; sudo install -m 0755 "$actual" /usr/local/sbin/bpftool'
    # GRUB's default entry-ordering (10_linux) lists installed kernels
    # newest-version-first and GRUB_DEFAULT=0 boots whichever is first --
    # installing a kernel OLDER than what's already on this guest (true for
    # several versions in Skyline Speeder's compatibility matrix, e.g. 6.1.180/6.6.148/
    # 6.12.101 vs a noble base image's 6.8.x) would otherwise silently keep
    # booting the OLD kernel after reboot, making every downstream check run
    # against the wrong kernel without any error. Pin the exact entry this
    # deploy just installed rather than relying on version-sort order.
    #
    # Ubuntu's default kernel packaging (which our own `make bindeb-pkg`
    # build reuses) names the non-recovery "Advanced options" submenu entry
    # for a bare version string (no "-generic" suffix, confirmed against
    # this project's own existing 6.18.40 build) exactly "Ubuntu, with
    # Linux ${VERSION}", with menuentry id
    # "gnulinux-${VERSION}-advanced-<UUID>" sharing the same <UUID> as the
    # submenu's own id -- this is GRUB's standard grub-mkconfig template,
    # not something Skyline Speeder generates, and is verified present before being
    # trusted (fail loudly rather than silently pinning a made-up id).
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        "SKYLINE_KERNEL_VERSION=$VERSION bash -s" <<'PIN_GRUB'
set -euo pipefail
VERSION=${SKYLINE_KERNEL_VERSION:?}
GRUB_CFG=/boot/grub/grub.cfg
submenu_line=$(sudo grep "^submenu 'Advanced options for Ubuntu'" "$GRUB_CFG")
submenu_id=$(printf '%s' "$submenu_line" | grep -oP "menuentry_id_option '\K[^']+")
uuid=${submenu_id#gnulinux-advanced-}
target_entry_id="gnulinux-${VERSION}-advanced-${uuid}"
if ! sudo grep -qF "'${target_entry_id}'" "$GRUB_CFG"; then
    echo "No GRUB menuentry '${target_entry_id}' for Linux ${VERSION} -- the" \
         "kernel package's postinst may not have run update-grub yet, or" \
         "Ubuntu's grub-mkconfig template changed. Not pinning a default;" \
         "the guest would boot whatever GRUB's normal version-sort picks." >&2
    exit 1
fi
sudo test -e /etc/default/grub.skyline-orig || sudo cp /etc/default/grub /etc/default/grub.skyline-orig
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
sudo update-grub
sudo grub-set-default "${submenu_id}>${target_entry_id}"
echo "Pinned GRUB default to Linux ${VERSION}: $(sudo grub-editenv list)"
PIN_GRUB
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$KNOWN_HOSTS" -p "$port" "$host" \
        sha256sum "$REMOTE_DIR"/*.deb
done

echo "Kernel packages installed on both guests, GRUB default pinned to ${VERSION}."
echo "Reboot each guest explicitly, then verify uname -r == ${VERSION} and config hashes."
echo "Rollback: sudo grub-set-default to a different menuentry (see grub.cfg), or restore /etc/default/grub.skyline-orig + update-grub."
