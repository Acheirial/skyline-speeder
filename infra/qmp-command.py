#!/usr/bin/env python3
"""Send one command to a local QEMU Machine Protocol socket."""

from __future__ import annotations

import argparse
import json
import socket


def receive_message(stream):
    line = stream.readline()
    if not line:
        raise RuntimeError("QMP socket closed before a response was received")
    return json.loads(line)


def send_message(stream, payload):
    stream.write(json.dumps(payload).encode("utf-8") + b"\r\n")
    stream.flush()


def execute(socket_path, command, timeout):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(socket_path)
        with connection.makefile("rwb") as stream:
            greeting = receive_message(stream)
            if "QMP" not in greeting:
                raise RuntimeError(f"invalid QMP greeting: {greeting}")
            send_message(stream, {"execute": "qmp_capabilities"})
            capabilities = receive_message(stream)
            if "error" in capabilities:
                raise RuntimeError(f"QMP capabilities failed: {capabilities}")
            send_message(stream, {"execute": command})
            response = receive_message(stream)
            if "error" in response:
                raise RuntimeError(f"QMP command failed: {response}")
            return response


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("socket_path")
    parser.add_argument("command")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    print(
        json.dumps(
            execute(args.socket_path, args.command, args.timeout),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
