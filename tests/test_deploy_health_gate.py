"""Tests for the health gate of .github/workflows/deploy-service.yml.

The `run:` script of the step "Wait until the new version is healthy" is read from the workflow file
and executed with bash against a local HTTP server, so these tests exercise exactly what CI runs.
`sleep` is replaced by a no-op on PATH to keep the 60 polling attempts fast.

Run: python3 -m unittest discover -s tests -v   (needs bash, curl, jq and PyYAML)
"""

import http.server
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/deploy-service.yml"
STEP_NAME = "Wait until the new version is healthy"
SHA = "0123456789abcdef0123456789abcdef01234567"
ATTEMPTS = 60
WARNING_TITLE = "Deployed with degraded health"


def setUpModule():
    # Fail, never skip: without jq every 200 response would be rejected and the suite would prove nothing.
    for tool in ("bash", "curl", "jq"):
        if shutil.which(tool) is None:
            raise RuntimeError(
                "%s not found on PATH: the health gate tests need bash, curl, jq and PyYAML "
                "(Ubuntu: sudo apt-get install -y curl jq python3-yaml)" % tool
            )


def gate_script():
    workflow = yaml.safe_load(WORKFLOW.read_text())
    steps = workflow["jobs"]["deploy"]["steps"]
    (step,) = [s for s in steps if s.get("name") == STEP_NAME]
    return step["run"]


def ok(status="ok", version=SHA):
    return (200, '{"status":"%s","version":"%s"}' % (status, version))


DROP = "drop"  # close the connection without a response: a curl transport error


class Server:
    """Answers GET requests with the scripted (status, body) responses; the last one repeats."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = 0
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                index = min(server.requests, len(server.responses) - 1)
                server.requests += 1
                response = server.responses[index]
                if response == DROP:
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                code, body = response
                data = body.encode()
                self.send_response(code)
                if 300 <= code < 400:
                    self.send_header("Location", "/health")
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d/health" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class HealthGateTest(unittest.TestCase):
    script = gate_script()

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        fake_sleep = bin_dir / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n")
        fake_sleep.chmod(0o755)
        self.path = "%s:%s" % (bin_dir, os.environ["PATH"])

    def run_gate(self, url, check_version="true"):
        summary = self.tmp / "summary.md"
        summary.write_text("")
        env = {
            "PATH": self.path,
            "HEALTH_URL": url,
            "CHECK_VERSION": check_version,
            "GITHUB_SHA": SHA,
            "GITHUB_STEP_SUMMARY": str(summary),
        }
        # Same shell as a GitHub Actions `run:` step: bash -e {0}
        proc = subprocess.run(
            ["bash", "-e", "-c", self.script], env=env, capture_output=True, text=True, timeout=60
        )
        return proc, summary.read_text()

    def gate(self, responses, check_version="true"):
        server = Server(responses)
        self.addCleanup(server.close)
        proc, summary = self.run_gate(server.url, check_version)
        return proc, summary, server.requests

    def assertAccepted(self, proc, summary, degraded):
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Healthy:", summary)
        if degraded:
            self.assertIn("::warning title=%s::" % WARNING_TITLE, proc.stdout)
            self.assertIn("[!WARNING]", summary)
            self.assertIn("**degraded**", summary)
        else:
            self.assertNotIn(WARNING_TITLE, proc.stdout)
            self.assertNotIn("[!WARNING]", summary)

    def assertRejected(self, proc, summary, requests=ATTEMPTS):
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(requests, ATTEMPTS)
        self.assertIn("did not report a healthy new version", proc.stdout)
        self.assertEqual(summary, "")  # no "Healthy" line, no degraded warning
        self.assertNotIn(WARNING_TITLE, proc.stdout)

    # --- accepted ---------------------------------------------------------------------------

    def test_ok_with_expected_version_is_accepted_without_warning(self):
        proc, summary, requests = self.gate([ok("ok")])
        self.assertAccepted(proc, summary, degraded=False)
        self.assertEqual(requests, 1)

    def test_degraded_with_expected_version_is_accepted_with_warning(self):
        proc, summary, requests = self.gate([ok("degraded")])
        self.assertAccepted(proc, summary, degraded=True)
        self.assertEqual(requests, 1)

    def test_check_version_false_accepts_both_statuses_without_matching_version(self):
        for status in ("ok", "degraded"):
            for body in (
                '{"status":"%s","version":"old"}' % status,
                '{"status":"%s"}' % status,
            ):
                with self.subTest(body=body):
                    proc, summary, _ = self.gate([(200, body)], check_version="false")
                    self.assertAccepted(proc, summary, degraded=status == "degraded")

    def test_rejected_probes_then_valid_response_is_accepted(self):
        proc, summary, requests = self.gate([
            DROP,
            (503, '{"status":"ok","version":"%s"}' % SHA),
            ok("degraded", version="old-sha"),
            (200, "not json"),
            ok("degraded"),
        ])
        self.assertAccepted(proc, summary, degraded=True)
        self.assertEqual(requests, 5)
        self.assertIn("curl exit", proc.stdout)
        self.assertIn("HTTP 503", proc.stdout)
        self.assertIn('version "old-sha"', proc.stdout)

    # --- rejected (every attempt is used, then exit 1) --------------------------------------

    def test_wrong_or_missing_version_is_rejected(self):
        for body in (
            '{"status":"ok","version":"old-sha"}',
            '{"status":"degraded","version":"old-sha"}',
            '{"status":"ok"}',
            '{"status":"degraded","version":null}',
        ):
            with self.subTest(body=body):
                self.assertRejected(*self.gate([(200, body)]))

    def test_http_503_with_acceptable_body_is_rejected(self):
        for status in ("ok", "degraded"):
            with self.subTest(status=status):
                self.assertRejected(*self.gate([(503, ok(status)[1])]))

    def test_redirect_and_other_non_200_are_rejected(self):
        for code in (301, 302, 204, 404, 500):
            with self.subTest(code=code):
                self.assertRejected(*self.gate([(code, ok()[1] if code != 204 else "")]))

    def test_invalid_bodies_are_rejected(self):
        for body in (
            "",
            "not json",
            '{"status":"ok","version":',
            "null",
            '"ok"',
            '["ok"]',
            "42",
            '{"version":"%s"}' % SHA,
            '{"status":"error","version":"%s"}' % SHA,
            '{"status":"OK","version":"%s"}' % SHA,
            '{"status":null,"version":"%s"}' % SHA,
            '{"status":"ok","version":"%s"} {"status":"ok"}' % SHA,
        ):
            with self.subTest(body=body):
                self.assertRejected(*self.gate([(200, body)]))

    def test_transport_failure_is_retried_and_never_accepted(self):
        proc, summary, requests = self.gate([DROP])
        self.assertRejected(proc, summary, requests)
        self.assertIn("curl exit", proc.stdout)

    def test_unreachable_endpoint_exhausts_attempts(self):
        with socket.socket() as s:  # a port nothing listens on
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        proc, summary = self.run_gate("http://127.0.0.1:%d/health" % port)
        self.assertRejected(proc, summary, requests=ATTEMPTS)
        self.assertEqual(proc.stdout.count("Waiting ("), ATTEMPTS)


if __name__ == "__main__":
    unittest.main()
