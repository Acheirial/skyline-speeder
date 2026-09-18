#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [DESTINATION] [--allow-proxy]

Download the Ubuntu 24.04 cloud image without overwriting an existing file.
EOF
}

DESTINATION=build/images/noble-server-cloudimg-amd64.img
ALLOW_PROXY=
case "$#" in
    0)
        ;;
    1)
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --allow-proxy)
                ALLOW_PROXY=$1
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 2
                ;;
            *)
                DESTINATION=$1
                ;;
        esac
        ;;
    2)
        if [[ "$1" = -* ]] || [ "$2" != --allow-proxy ]; then
            usage >&2
            exit 2
        fi
        DESTINATION=$1
        ALLOW_PROXY=$2
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

OFFICIAL_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
MIRROR_URL=${SKYLINE_UBUNTU_IMAGE_MIRROR_URL:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images/noble/current/noble-server-cloudimg-amd64.img}

mkdir -p -- "$(dirname -- "$DESTINATION")"
if [ -e "$DESTINATION" ]; then
    echo "Refusing to overwrite existing image: $DESTINATION" >&2
    exit 1
fi

download_direct() {
    local url=$1
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
        curl --noproxy '*' -L --fail --show-error --continue-at - \
        --output "$DESTINATION.part" "$url"
}

if [ -n "$MIRROR_URL" ]; then
    echo "Trying configured mirror: $MIRROR_URL"
    if download_direct "$MIRROR_URL"; then
        mv -- "$DESTINATION.part" "$DESTINATION"
        exit 0
    fi
fi

echo "Trying official source without proxy: $OFFICIAL_URL"
if download_direct "$OFFICIAL_URL"; then
    mv -- "$DESTINATION.part" "$DESTINATION"
    exit 0
fi

if [ "$ALLOW_PROXY" = --allow-proxy ]; then
    echo "Mirror/direct attempts failed; trying inherited proxy configuration."
    curl -L --fail --show-error --continue-at - \
        --output "$DESTINATION.part" "$OFFICIAL_URL"
    mv -- "$DESTINATION.part" "$DESTINATION"
    exit 0
fi

echo "Download failed. Re-run with --allow-proxy only after mirror and direct failures." >&2
exit 1
