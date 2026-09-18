import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_DIR))

from matrix_lib import expand_runs, load_manifest
from run_matrix import (
    case_attempts,
    communicate_or_terminate,
    execution_identity,
    load_analysis_invalid_case_ids,
    successful_attempt,
    validate_execution_class,
)


class RunnerTests(unittest.TestCase):
    def test_execution_identity_ignores_mutable_runtime_fields(self):
        first = {
            "execution_class": "tcg-validation",
            "performance_valid": False,
            "acceleration": "tcg",
            "qemu": {"version": "8.2"},
            "host_kernel": "6.8",
            "resources": {"vcpus": 2},
            "server": {"image": "/images/server.qcow2", "pid": 1},
            "client": {"image": "/images/client.qcow2", "pid": 2},
        }
        second = json.loads(json.dumps(first))
        second["server"]["pid"] = 100
        second["client"]["pid"] = 200
        second["started_at"] = "later"
        self.assertEqual(execution_identity(first), execution_identity(second))

    def test_execution_class_mismatch_is_rejected(self):
        manifest = load_manifest(
            EXPERIMENT_DIR / "manifests" / "kernel-compat-smoke-tcg.toml"
        )
        with self.assertRaisesRegex(RuntimeError, "execution class mismatch"):
            validate_execution_class(
                manifest,
                {"execution_class": "formal-kvm", "performance_valid": True},
            )

    def test_resume_finds_latest_successful_attempt(self):
        manifest = load_manifest(
            EXPERIMENT_DIR / "manifests" / "kernel-compat-smoke-tcg.toml"
        )
        case = expand_runs(manifest)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for attempt, valid in ((1, False), (2, True)):
                path = root / f"{case.case_id}--attempt{attempt:02d}"
                path.mkdir()
                (path / "status.json").write_text(
                    json.dumps({"valid": valid}), encoding="utf-8"
                )
            attempts = case_attempts(root, case)
            self.assertEqual([number for number, _ in attempts], [1, 2])
            self.assertTrue(successful_attempt(attempts).name.endswith("attempt02"))

    def test_load_analysis_invalid_case_ids_selects_non_true_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            csv_path = Path(directory) / "runs.csv"
            csv_path.write_text(
                "case_id,valid\n"
                "a--rtt100,True\n"
                "b--rtt200,False\n"
                "c--rtt300,\n",
                encoding="utf-8",
            )
            self.assertEqual(
                load_analysis_invalid_case_ids(csv_path),
                {"b--rtt200", "c--rtt300"},
            )

    def test_communicate_or_terminate_returns_output_for_finished_process(self):
        # text=True matches Remote.popen()'s real construction -- the
        # actual server_process/metrics_process/perf_process objects this
        # is used on all decode to str, which write_text() requires.
        process = subprocess.Popen(
            ["echo", "hello"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        code, stdout, stderr = communicate_or_terminate(process, 5)
        self.assertEqual(code, 0)
        self.assertEqual(stdout, "hello\n")
        self.assertEqual(stderr, "")

    def test_communicate_or_terminate_terminates_a_hung_process(self):
        process = subprocess.Popen(
            ["sleep", "60"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        communicate_or_terminate(process, 0.2)
        # terminate_process() inside communicate_or_terminate must have
        # actually reaped it -- a case that fails early must not leave
        # orphaned guest-side processes behind for the next case to trip
        # over.
        self.assertIsNotNone(process.poll())


if __name__ == "__main__":
    unittest.main()
