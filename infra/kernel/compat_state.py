#!/usr/bin/env python3
"""Tiny state.json read/merge helper for infra/kernel/run-compat-pipeline.sh
(bash has no sane native JSON manipulation, and this file's schema -- see
research/experiments/render_kernel_compat_report.py's module docstring --
is nested enough that hand-rolled jq/sed patching would be its own source
of bugs). Not a library: intentionally a tiny CLI, invoked once per state
update from the orchestrator script.

Usage:
    compat_state.py init PATH VERSION
        Creates PATH with a fresh default state if it doesn't already
        exist; a no-op (does not touch the existing file) if it does.
    compat_state.py patch PATH
        Reads a JSON object from stdin and deep-merges it into PATH
        (dicts merge key-by-key recursively; any other value type
        replaces the existing one outright). Writes PATH back out.
    compat_state.py get PATH DOTTED.KEY.PATH
        Prints the value at that path (JSON-encoded if it's a dict/list,
        raw if it's a string/number/bool, empty string if missing/None)
        to stdout. Exit 0 either way -- a missing key is not an error,
        the orchestrator's shell logic decides what a missing value means.
"""
import json
import sys
from pathlib import Path


def default_state(version):
    return {
        "version": version,
        "overall": "running",
        "identity": {},
        "stages": {},
        "capabilities": {},
        "artifacts": {},
    }


def deep_merge(base, patch):
    for key, value in patch.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def load(path):
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    if not text.strip():
        return None
    return json.loads(text)


def save(path, state):
    path.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


def cmd_init(path, version):
    if load(path) is None:
        path.parent.mkdir(parents=True, exist_ok=True)
        save(path, default_state(version))


def cmd_patch(path):
    patch = json.loads(sys.stdin.read())
    state = load(path)
    if state is None:
        state = default_state(patch.get("version", "unknown"))
    deep_merge(state, patch)
    save(path, state)


def cmd_get(path, dotted_key):
    state = load(path) or {}
    node = state
    for key in dotted_key.split("."):
        if not isinstance(node, dict) or key not in node:
            print("")
            return
        node = node[key]
    if node is None:
        print("")
    elif isinstance(node, (dict, list)):
        print(json.dumps(node))
    elif isinstance(node, bool):
        print("true" if node else "false")
    else:
        print(node)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, path = sys.argv[1], Path(sys.argv[2])
    if cmd == "init":
        if len(sys.argv) < 4:
            print("init requires VERSION", file=sys.stderr)
            return 2
        cmd_init(path, sys.argv[3])
    elif cmd == "patch":
        cmd_patch(path)
    elif cmd == "get":
        if len(sys.argv) < 4:
            print("get requires DOTTED.KEY.PATH", file=sys.stderr)
            return 2
        cmd_get(path, sys.argv[3])
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
