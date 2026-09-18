#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-plan}
if [ "$#" -gt 0 ]; then
    shift
fi
ACCELERATION=kvm
CONFIRM_STOP=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --accel)
            ACCELERATION=${2:-}
            shift 2
            ;;
        --allow-tcg)
            ACCELERATION=tcg
            shift
            ;;
        --confirm-stop)
            CONFIRM_STOP=1
            shift
            ;;
        -h|--help)
            ACTION=help
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

case "$ACCELERATION" in
    kvm|tcg) ;;
    *) echo "Acceleration must be kvm or tcg" >&2; exit 2 ;;
esac

QEMU=${QEMU:-qemu-system-x86_64}
QEMU=$(realpath -- "$(command -v "$QEMU")")
PYTHON=${SKYLINE_PYTHON:-.venv/bin/python}
SERVER_IMAGE=${SKYLINE_SERVER_IMAGE:-build/images/server.qcow2}
CLIENT_IMAGE=${SKYLINE_CLIENT_IMAGE:-build/images/client.qcow2}
SERVER_SEED=${SKYLINE_SERVER_SEED:-build/images/server-seed.img}
CLIENT_SEED=${SKYLINE_CLIENT_SEED:-build/images/client-seed.img}
RUN_DIR=${SKYLINE_RUN_DIR:-build/run}
if [ "$ACCELERATION" = tcg ]; then
    MEMORY_MIB=${SKYLINE_VM_MEMORY_MIB:-4096}
    VCPUS=${SKYLINE_VM_VCPUS:-2}
else
    MEMORY_MIB=${SKYLINE_VM_MEMORY_MIB:-6144}
    VCPUS=${SKYLINE_VM_VCPUS:-4}
fi
SERVER_SSH_PORT=${SKYLINE_SERVER_SSH_PORT:-2222}
CLIENT_SSH_PORT=${SKYLINE_CLIENT_SSH_PORT:-2223}
STOP_TIMEOUT=${SKYLINE_VM_STOP_TIMEOUT:-120}
# taskset -c CPULIST syntax (e.g. "0-3" or "0,2,4,6"), applied to each QEMU
# process right after it starts. Unset (default) means "let the host
# scheduler place both VMs freely" -- the previous behavior, and still the
# only option on hosts with few CPUs. environment.json's own affinity
# field was historically populated by reading back whatever the scheduler
# happened to be doing, not by anything this script actually set -- that
# made it record-only, not a real isolation guarantee; a run investigating
# an unexplained stall should set these explicitly instead of trusting
# that field to reflect a deliberate choice.
SERVER_CPU_AFFINITY=${SKYLINE_SERVER_CPU_AFFINITY:-}
CLIENT_CPU_AFFINITY=${SKYLINE_CLIENT_CPU_AFFINITY:-}

usage() {
    cat <<EOF
Usage: $0 plan|start|status|stop [--accel kvm|tcg] [--confirm-stop]

TCG is an integration-validation environment. Its results are always marked
performance_valid=false. Both acceleration modes use the Host tap topology.
EOF
}

expand_cpu_list() {
    # Turns "0-3,6" into "0 1 2 3 6" -- same list syntax taskset -c takes,
    # used here only to check two lists don't overlap before ever handing
    # either to taskset itself.
    local cpu_list=$1
    local part
    IFS=',' read -ra parts <<<"$cpu_list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            seq "${part%-*}" "${part#*-}"
        else
            echo "$part"
        fi
    done
}

check_cpu_affinity_disjoint() {
    if [ -z "$SERVER_CPU_AFFINITY" ] || [ -z "$CLIENT_CPU_AFFINITY" ]; then
        return
    fi
    local overlap
    overlap=$(comm -12 \
        <(expand_cpu_list "$SERVER_CPU_AFFINITY" | sort -un) \
        <(expand_cpu_list "$CLIENT_CPU_AFFINITY" | sort -un))
    if [ -n "$overlap" ]; then
        echo "SKYLINE_SERVER_CPU_AFFINITY and SKYLINE_CLIENT_CPU_AFFINITY share CPU(s): $(tr '\n' ' ' <<<"$overlap")" >&2
        exit 1
    fi
}

apply_cpu_affinity() {
    local name=$1
    local cpu_list=$2
    local pid_file="$RUN_DIR/$name.pid"
    local pid
    if [ -z "$cpu_list" ]; then
        return
    fi
    pid=$(read_pid "$pid_file")
    taskset -pc "$cpu_list" "$pid"
}

absolute_path() {
    local path=$1
    if [ -e "$path" ]; then
        realpath -- "$path"
    else
        realpath -m -- "$path"
    fi
}

print_vm() {
    local name=$1
    local image=$2
    local seed=$3
    local tap=$4
    local ssh_port=$5
    cat <<EOF
$name:
  image: $(absolute_path "$image")
  seed: $(absolute_path "$seed")
  vCPU/RAM: $VCPUS / ${MEMORY_MIB} MiB
  acceleration: $ACCELERATION
  data backend: tap $tap
  management SSH: 127.0.0.1:$ssh_port
  QMP socket: $(absolute_path "$RUN_DIR/$name.qmp")
EOF
}

require_start_inputs() {
    local name=$1
    local image=$2
    local seed=$3
    local tap=$4
    local pid_file="$RUN_DIR/$name.pid"
    if [ ! -f "$image" ] || [ ! -f "$seed" ]; then
        echo "Missing image or cloud-init seed for $name" >&2
        exit 1
    fi
    if ! ip link show dev "$tap" >/dev/null 2>&1; then
        echo "Missing data tap $tap; run sudo infra/topology.sh up first" >&2
        exit 1
    fi
    if [ -e "$pid_file" ]; then
        echo "PID file already exists: $(absolute_path "$pid_file")" >&2
        exit 1
    fi
}

start_vm() {
    local name=$1
    local image=$2
    local seed=$3
    local tap=$4
    local ssh_port=$5
    local mgmt_mac=$6
    local data_mac=$7
    local pid_file="$RUN_DIR/$name.pid"
    local log_file="$RUN_DIR/$name.log"
    local console_file="$RUN_DIR/$name-console.log"
    local qmp_socket="$RUN_DIR/$name.qmp"
    local -a machine_args
    local -a data_args

    require_start_inputs "$name" "$image" "$seed" "$tap"
    if [ "$ACCELERATION" = tcg ]; then
        machine_args=(-accel tcg,thread=multi -cpu max)
        data_args=(-netdev "tap,id=data,ifname=${tap},script=no,downscript=no" \
                   -device "virtio-net-pci,netdev=data,mac=${data_mac}")
    else
        machine_args=(-accel kvm -cpu host)
        data_args=(-netdev "tap,id=data,ifname=${tap},script=no,downscript=no" \
                   -device "virtio-net-pci,netdev=data,mac=${data_mac},mq=on,vectors=10")
    fi
    "$QEMU" \
        -name "$name" "${machine_args[@]}" \
        -smp "$VCPUS" -m "$MEMORY_MIB" \
        -drive "file=$image,if=virtio,format=qcow2" \
        -drive "file=$seed,if=virtio,format=raw,readonly=on" \
        -netdev "user,id=mgmt,hostfwd=tcp:127.0.0.1:${ssh_port}-:22" \
        -device "virtio-net-pci,netdev=mgmt,mac=${mgmt_mac}" \
        "${data_args[@]}" \
        -qmp "unix:${qmp_socket},server=on,wait=off" \
        -display none -serial "file:$console_file" \
        -daemonize -pidfile "$pid_file" \
        -D "$log_file"
}

read_pid() {
    local pid_file=$1
    if [ -f "$pid_file" ]; then
        tr -d '[:space:]' < "$pid_file"
    fi
}

write_environment() {
    local server_pid client_pid server_image_abs client_image_abs
    local server_sha client_sha qemu_version server_affinity client_affinity
    local server_command client_command server_seed_sha client_seed_sha
    local execution_class performance_valid temporary server_qmp client_qmp
    server_pid=$(read_pid "$RUN_DIR/skyline-server.pid")
    client_pid=$(read_pid "$RUN_DIR/skyline-client.pid")
    server_image_abs=$(absolute_path "$SERVER_IMAGE")
    client_image_abs=$(absolute_path "$CLIENT_IMAGE")
    server_qmp=$(absolute_path "$RUN_DIR/skyline-server.qmp")
    client_qmp=$(absolute_path "$RUN_DIR/skyline-client.qmp")
    server_sha=${SERVER_IMAGE_SHA_AT_START:?missing server image start hash}
    client_sha=${CLIENT_IMAGE_SHA_AT_START:?missing client image start hash}
    qemu_version=$($QEMU --version | sed -n '1p')
    server_affinity=$(taskset -pc "$server_pid" 2>&1 || true)
    client_affinity=$(taskset -pc "$client_pid" 2>&1 || true)
    server_command=$(tr '\0' ' ' < "/proc/$server_pid/cmdline")
    client_command=$(tr '\0' ' ' < "/proc/$client_pid/cmdline")
    server_seed_sha=$(sha256sum -- "$SERVER_SEED" | awk '{print $1}')
    client_seed_sha=$(sha256sum -- "$CLIENT_SEED" | awk '{print $1}')
    if [ "$ACCELERATION" = tcg ]; then
        execution_class=tcg-validation
        performance_valid=false
    else
        execution_class=formal-kvm
        performance_valid=true
    fi
    temporary="$RUN_DIR/environment.json.part"
    jq -n \
        --arg execution_class "$execution_class" \
        --argjson performance_valid "$performance_valid" \
        --arg acceleration "$ACCELERATION" \
        --arg qemu "$QEMU" \
        --arg qemu_version "$qemu_version" \
        --arg host_kernel "$(uname -r)" \
        --arg started_at "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" \
        --arg server_image "$server_image_abs" \
        --arg client_image "$client_image_abs" \
        --arg server_sha "$server_sha" \
        --arg client_sha "$client_sha" \
        --arg server_affinity "$server_affinity" \
        --arg client_affinity "$client_affinity" \
        --arg server_affinity_requested "$SERVER_CPU_AFFINITY" \
        --arg client_affinity_requested "$CLIENT_CPU_AFFINITY" \
        --arg server_command "$server_command" \
        --arg client_command "$client_command" \
        --arg server_seed "$(absolute_path "$SERVER_SEED")" \
        --arg client_seed "$(absolute_path "$CLIENT_SEED")" \
        --arg server_seed_sha "$server_seed_sha" \
        --arg client_seed_sha "$client_seed_sha" \
        --arg server_qmp "$server_qmp" \
        --arg client_qmp "$client_qmp" \
        --argjson vcpus "$VCPUS" \
        --argjson memory_mib "$MEMORY_MIB" \
        --argjson server_pid "$server_pid" \
        --argjson client_pid "$client_pid" \
        --argjson server_ssh_port "$SERVER_SSH_PORT" \
        --argjson client_ssh_port "$CLIENT_SSH_PORT" \
        '{
          execution_class: $execution_class,
          performance_valid: $performance_valid,
          acceleration: $acceleration,
          qemu: {binary: $qemu, version: $qemu_version},
          host_kernel: $host_kernel,
          started_at: $started_at,
          resources: {vcpus: $vcpus, memory_mib: $memory_mib},
          server: {
            image: $server_image, image_sha256_at_start: $server_sha,
            seed: $server_seed, seed_sha256: $server_seed_sha,
            pid: $server_pid, qmp: $server_qmp,
            ssh_port: $server_ssh_port, affinity: $server_affinity,
            affinity_requested: $server_affinity_requested,
            command: $server_command
          },
          client: {
            image: $client_image, image_sha256_at_start: $client_sha,
            seed: $client_seed, seed_sha256: $client_seed_sha,
            pid: $client_pid, qmp: $client_qmp,
            ssh_port: $client_ssh_port, affinity: $client_affinity,
            affinity_requested: $client_affinity_requested,
            command: $client_command
          }
        }' > "$temporary"
    mv -- "$temporary" "$RUN_DIR/environment.json"
}

qmp_is_running() {
    local qmp_socket=$1
    [ -S "$qmp_socket" ] &&
        "$PYTHON" infra/qmp-command.py "$qmp_socket" query-status \
            >/dev/null 2>&1
}

vm_is_running() {
    local pid=$1
    local qmp_socket=$2
    kill -0 "$pid" 2>/dev/null || qmp_is_running "$qmp_socket"
}

wait_for_exit() {
    local pid=$1
    local qmp_socket=$2
    local timeout=$3
    local elapsed=0
    while vm_is_running "$pid" "$qmp_socket"; do
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

stop_vm() {
    local name=$1
    local pid_file="$RUN_DIR/$name.pid"
    local qmp_socket="$RUN_DIR/$name.qmp"
    local pid
    pid=$(read_pid "$pid_file")
    if [ -z "$pid" ]; then
        echo "$name has no PID file"
        return
    fi
    if ! vm_is_running "$pid" "$qmp_socket"; then
        echo "$name has stale PID $pid; removing only its PID/QMP runtime files"
        rm -f -- "$pid_file" "$qmp_socket"
        return
    fi
    if [ ! -S "$qmp_socket" ]; then
        echo "$name QMP socket is missing: $(absolute_path "$qmp_socket")" >&2
        return 1
    fi
    "$PYTHON" infra/qmp-command.py "$qmp_socket" system_powerdown
    if ! wait_for_exit "$pid" "$qmp_socket" "$STOP_TIMEOUT"; then
        echo "$name did not stop within ${STOP_TIMEOUT}s; requesting QMP quit" >&2
        "$PYTHON" infra/qmp-command.py "$qmp_socket" quit
        wait_for_exit "$pid" "$qmp_socket" 15 || {
            echo "$name remains alive as PID $pid; runtime files were preserved" >&2
            return 1
        }
    fi
    rm -f -- "$pid_file" "$qmp_socket"
    echo "$name stopped; logs and images were preserved"
}

case "$ACTION" in
    help|-h|--help)
        usage
        ;;
    plan)
        print_vm skyline-server "$SERVER_IMAGE" "$SERVER_SEED" skyline-tap-server "$SERVER_SSH_PORT"
        print_vm skyline-client "$CLIENT_IMAGE" "$CLIENT_SEED" skyline-tap-client "$CLIENT_SSH_PORT"
        ;;
    start)
        if [ "$ACCELERATION" = kvm ] && [ ! -w /dev/kvm ]; then
            echo "Writable /dev/kvm is required for KVM mode" >&2
            exit 1
        fi
        mkdir -p -- "$RUN_DIR"
        require_start_inputs skyline-server "$SERVER_IMAGE" "$SERVER_SEED" skyline-tap-server
        require_start_inputs skyline-client "$CLIENT_IMAGE" "$CLIENT_SEED" skyline-tap-client
        check_cpu_affinity_disjoint
        SERVER_IMAGE_SHA_AT_START=$(sha256sum -- "$SERVER_IMAGE" | awk '{print $1}')
        CLIENT_IMAGE_SHA_AT_START=$(sha256sum -- "$CLIENT_IMAGE" | awk '{print $1}')
        start_vm skyline-server "$SERVER_IMAGE" "$SERVER_SEED" skyline-tap-server \
            "$SERVER_SSH_PORT" 52:54:00:10:00:01 52:54:00:20:00:01
        start_vm skyline-client "$CLIENT_IMAGE" "$CLIENT_SEED" skyline-tap-client \
            "$CLIENT_SSH_PORT" 52:54:00:10:00:02 52:54:00:20:00:02
        apply_cpu_affinity skyline-server "$SERVER_CPU_AFFINITY"
        apply_cpu_affinity skyline-client "$CLIENT_CPU_AFFINITY"
        write_environment
        echo "VMs started in $ACCELERATION mode; inspect $RUN_DIR/environment.json"
        ;;
    status)
        for name in skyline-server skyline-client; do
            pid=$(read_pid "$RUN_DIR/$name.pid")
            if [ -z "$pid" ]; then
                echo "$name stopped"
            elif vm_is_running "$pid" "$RUN_DIR/$name.qmp"; then
                echo "$name running pid=$pid qmp=$(absolute_path "$RUN_DIR/$name.qmp")"
            else
                echo "$name stale pid=$pid"
            fi
        done
        if [ -f "$RUN_DIR/environment.json" ]; then
            jq '{execution_class, performance_valid, acceleration, resources}' \
                "$RUN_DIR/environment.json"
        fi
        ;;
    stop)
        print_vm skyline-server "$SERVER_IMAGE" "$SERVER_SEED" skyline-tap-server "$SERVER_SSH_PORT"
        print_vm skyline-client "$CLIENT_IMAGE" "$CLIENT_SEED" skyline-tap-client "$CLIENT_SSH_PORT"
        if [ "$CONFIRM_STOP" -ne 1 ]; then
            cat <<EOF
This requests guest shutdown for the two named Skyline Speeder VMs and removes only their
PID/QMP runtime files after the QEMU processes exit. Images, logs and results
are preserved. Re-run with --confirm-stop.
EOF
            exit 2
        fi
        stop_vm skyline-client
        stop_vm skyline-server
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
