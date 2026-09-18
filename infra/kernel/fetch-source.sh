#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 [DESTINATION] [--allow-proxy]

Download and record the configured Linux kernel source archive.
EOF
}

VERSION=${SKYLINE_KERNEL_VERSION:-6.18.40}
DESTINATION=build/kernel/linux-${VERSION}.tar.xz
ALLOW_PROXY=
SOURCE_URL=
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

# kernel.org buckets releases by major version (v6.x/, v7.x/, ...), not a
# fixed "v6.x" -- derive it from VERSION's leading dot-segment so this
# works for 7.1.6 and beyond, not just the 6.y.z line.
KERNEL_MAJOR=${VERSION%%.*}
OFFICIAL_URL="https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_MAJOR}.x/linux-${VERSION}.tar.xz"
MIRROR_URL=${SKYLINE_KERNEL_MIRROR_URL:-}

mkdir -p -- "$(dirname -- "$DESTINATION")"
if [ -e "$DESTINATION" ]; then
    echo "Refusing to overwrite existing kernel archive: $DESTINATION" >&2
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
        SOURCE_URL=$MIRROR_URL
    fi
fi
if [ ! -e "$DESTINATION" ]; then
    echo "Trying kernel.org without proxy: $OFFICIAL_URL"
    if download_direct "$OFFICIAL_URL"; then
        mv -- "$DESTINATION.part" "$DESTINATION"
        SOURCE_URL=$OFFICIAL_URL
    fi
fi
if [ ! -e "$DESTINATION" ] && [ "$ALLOW_PROXY" = --allow-proxy ]; then
    echo "Mirror/direct attempts failed; trying inherited proxy configuration."
    curl -L --fail --show-error --continue-at - \
        --output "$DESTINATION.part" "$OFFICIAL_URL"
    mv -- "$DESTINATION.part" "$DESTINATION"
    SOURCE_URL=$OFFICIAL_URL
fi
if [ ! -e "$DESTINATION" ]; then
    echo "Kernel download failed; proxy fallback was not authorized." >&2
    exit 1
fi

sha256sum -- "$DESTINATION" | tee -- "$DESTINATION.sha256"
echo "$SOURCE_URL" > "$DESTINATION.source-url"
echo "Downloaded and recorded Linux $VERSION source archive."
