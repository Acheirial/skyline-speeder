#!/usr/bin/env bash
set -euo pipefail

ACTION=${1:-count}
START_LINE=${2:-1}
EVENTS_PATH=${SKYLINE_EVENTS_PATH:-/run/skyline-speeder/events.jsonl}

case "$ACTION" in
    count)
        if [ -f "$EVENTS_PATH" ]; then
            wc -l < "$EVENTS_PATH"
        else
            echo 0
        fi
        ;;
    from)
        if [ ! -f "$EVENTS_PATH" ]; then
            exit 0
        fi
        if ! [[ "$START_LINE" =~ ^[0-9]+$ ]] || [ "$START_LINE" -lt 1 ]; then
            echo "START_LINE must be a positive integer" >&2
            exit 2
        fi
        sed -n "${START_LINE},\$p" "$EVENTS_PATH"
        ;;
    *)
        echo "Usage: $0 count|from [START_LINE]" >&2
        exit 2
        ;;
esac

