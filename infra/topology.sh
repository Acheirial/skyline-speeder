#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-plan}
CONFIRM=${2:-}
RUN_USER=${SKYLINE_QEMU_USER:-${SUDO_USER:-$(id -un)}}
ROUTER_NS=skyline-router
SERVER_BRIDGE=skyline-br-server
CLIENT_BRIDGE=skyline-br-client
SERVER_TAP=skyline-tap-server
CLIENT_TAP=skyline-tap-client
SERVER_HOST_VETH=skyline-srv-host
SERVER_ROUTER_VETH=skyline-srv-rtr
CLIENT_HOST_VETH=skyline-cli-host
CLIENT_ROUTER_VETH=skyline-cli-rtr

print_plan() {
    cat <<EOF
Skyline Speeder test topology:
  router namespace: $ROUTER_NS
  server bridge/tap: $SERVER_BRIDGE / $SERVER_TAP
  client bridge/tap: $CLIENT_BRIDGE / $CLIENT_TAP
  server host/router veth: $SERVER_HOST_VETH / $SERVER_ROUTER_VETH
  client host/router veth: $CLIENT_HOST_VETH / $CLIENT_ROUTER_VETH
  server data subnet: 10.20.1.0/24, router 10.20.1.1, guest 10.20.1.2
  client data subnet: 10.20.2.0/24, router 10.20.2.1, guest 10.20.2.2
  server data subnet (v6, ULA): fd20:1::/64, router fd20:1::1, guest fd20:1::2
  client data subnet (v6, ULA): fd20:2::/64, router fd20:2::1, guest fd20:2::2
  QEMU tap owner: $RUN_USER
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This action requires root." >&2
        exit 1
    fi
}

validate_interface_names() {
    local name
    for name in "$SERVER_BRIDGE" "$CLIENT_BRIDGE" "$SERVER_TAP" "$CLIENT_TAP" \
        "$SERVER_HOST_VETH" "$SERVER_ROUTER_VETH" \
        "$CLIENT_HOST_VETH" "$CLIENT_ROUTER_VETH"; do
        if [ "${#name}" -gt 15 ]; then
            echo "Linux interface name exceeds 15 bytes: $name" >&2
            exit 1
        fi
    done
}

case "$ACTION" in
    plan)
        print_plan
        ;;
    status)
        ip netns list
        ip -brief link show "$SERVER_BRIDGE" 2>/dev/null || true
        ip -brief link show "$CLIENT_BRIDGE" 2>/dev/null || true
        ip -brief link show "$SERVER_TAP" 2>/dev/null || true
        ip -brief link show "$CLIENT_TAP" 2>/dev/null || true
        ;;
    up)
        require_root
        validate_interface_names
        if ip netns list | awk '{print $1}' | grep -Fxq "$ROUTER_NS"; then
            echo "Topology already exists; refusing to modify it." >&2
            exit 1
        fi
        print_plan
        ip netns add "$ROUTER_NS"
        ip link add name "$SERVER_BRIDGE" type bridge
        ip link add name "$CLIENT_BRIDGE" type bridge
        ip link add "$SERVER_HOST_VETH" type veth peer name "$SERVER_ROUTER_VETH"
        ip link add "$CLIENT_HOST_VETH" type veth peer name "$CLIENT_ROUTER_VETH"
        ip tuntap add dev "$SERVER_TAP" mode tap user "$RUN_USER"
        ip tuntap add dev "$CLIENT_TAP" mode tap user "$RUN_USER"
        ip link set "$SERVER_ROUTER_VETH" netns "$ROUTER_NS"
        ip link set "$CLIENT_ROUTER_VETH" netns "$ROUTER_NS"
        ip link set "$SERVER_HOST_VETH" master "$SERVER_BRIDGE"
        ip link set "$SERVER_TAP" master "$SERVER_BRIDGE"
        ip link set "$CLIENT_HOST_VETH" master "$CLIENT_BRIDGE"
        ip link set "$CLIENT_TAP" master "$CLIENT_BRIDGE"
        ip link set "$SERVER_BRIDGE" up
        ip link set "$CLIENT_BRIDGE" up
        ip link set "$SERVER_HOST_VETH" up
        ip link set "$CLIENT_HOST_VETH" up
        ip link set "$SERVER_TAP" up
        ip link set "$CLIENT_TAP" up
        ip -n "$ROUTER_NS" addr add 10.20.1.1/24 dev "$SERVER_ROUTER_VETH"
        ip -n "$ROUTER_NS" addr add 10.20.2.1/24 dev "$CLIENT_ROUTER_VETH"
        # ULA prefixes mirroring the IPv4 /24s above -- fd20:1::/64 <-> 10.20.1.0/24,
        # fd20:2::/64 <-> 10.20.2.0/24, same .1 router / .2 guest numbering.
        ip -n "$ROUTER_NS" -6 addr add fd20:1::1/64 dev "$SERVER_ROUTER_VETH"
        ip -n "$ROUTER_NS" -6 addr add fd20:2::1/64 dev "$CLIENT_ROUTER_VETH"
        ip -n "$ROUTER_NS" link set lo up
        ip -n "$ROUTER_NS" link set "$SERVER_ROUTER_VETH" up
        ip -n "$ROUTER_NS" link set "$CLIENT_ROUTER_VETH" up
        ip netns exec "$ROUTER_NS" sysctl -qw net.ipv4.ip_forward=1
        ip netns exec "$ROUTER_NS" sysctl -qw net.ipv6.conf.all.forwarding=1
        # Router advertises no RA/autoconf here -- guests get their v6 address
        # from cloud-init static config (infra/cloud-init/network-*.yaml), not
        # from this namespace, so disable accept_ra to avoid a stray default
        # route from any future RA source overriding the static one.
        ip netns exec "$ROUTER_NS" sysctl -qw net.ipv6.conf.all.accept_ra=0
        echo "Topology created."
        ;;
    down)
        require_root
        if [ "$CONFIRM" != --confirm-down ]; then
            print_plan
            cat <<EOF
This removes only the Skyline Speeder test namespace, bridges, taps and veth devices named above.
Re-run with: $0 down --confirm-down
EOF
            exit 2
        fi
        ip netns delete "$ROUTER_NS" 2>/dev/null || true
        for interface in "$SERVER_TAP" "$CLIENT_TAP" \
            "$SERVER_HOST_VETH" "$CLIENT_HOST_VETH" \
            "$SERVER_BRIDGE" "$CLIENT_BRIDGE"; do
            if ip link show dev "$interface" >/dev/null 2>&1; then
                ip link delete "$interface"
            fi
        done
        if ip netns list | awk '{print $1}' | grep -Fxq "$ROUTER_NS"; then
            echo "Failed to remove router namespace $ROUTER_NS" >&2
            exit 1
        fi
        for interface in "$SERVER_TAP" "$CLIENT_TAP" \
            "$SERVER_HOST_VETH" "$CLIENT_HOST_VETH" \
            "$SERVER_BRIDGE" "$CLIENT_BRIDGE"; do
            if ip link show dev "$interface" >/dev/null 2>&1; then
                echo "Failed to remove interface $interface" >&2
                exit 1
            fi
        done
        echo "Skyline Speeder test topology removed."
        ;;
    *)
        echo "Usage: $0 plan|status|up|down [--confirm-down]" >&2
        exit 2
        ;;
esac
