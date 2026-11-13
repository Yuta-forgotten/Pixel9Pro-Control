"""Exercise the production DNS CGI with only Android IPC replaced."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DnsCacheTest(unittest.TestCase):
    def setUp(self):
        scratch = ROOT.parent / "work"
        scratch.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="dns-cache-", dir=scratch)
        self.work = Path(self.temp.name)
        self.mod = self.work / "module"
        for name in ["webroot/cgi-bin/_common.sh", "webroot/cgi-bin/dns_cache.sh"]:
            dst = self.mod / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, dst)
        (self.mod / ".webui_token").write_text("fixture-dns-token")
        self.service = self.work / "service"
        self.service.write_text("""#!/bin/sh
case "$1:$3" in
list:)
    [ "$CASE" != descriptor ] || { echo '1 dnsresolver: [wrong.Interface]'; exit; }
    echo '1 dnsresolver: [android.net.IDnsResolver]' ;;
call:16777215)
    if [ "$CASE" = version ]; then echo 'Result: Parcel(00000000 00000003)'
    else echo "Result: Parcel(00000000 00000012   '........')"; fi ;;
call:11)
    printf '%s\\n' "$5" >> "$FIXTURE/calls"
    case "$CASE:$5" in
    partial:105) echo 'Result: Parcel(fffffff8 00000000 00000040)';;
    denied:*) echo 'Result: Parcel(ffffffff 00000000)';;
    timeout:*) exit 124;;
    malformed:*) echo 'Result: Parcel(NULL)';;
    *) echo "Result: Parcel(00000000   '....')";;
    esac ;;
*) exit 64;;
esac
""")
        self.dumpsys = self.work / "dumpsys"
        self.dumpsys.write_text("""#!/bin/sh
[ "$1:$2:$3" = '-t:10:dnsresolver' ] || exit 64
case "$CASE" in
empty) echo 'PrivateDnsLog:';;
dump_timeout) echo 'NetId: 100'; exit 124;;
invalid_network) printf 'NetId: 100\\nNetId: 999999\\n';;
*) printf 'NetId: 100\\n  DNS servers: 1\\nNetId: 105\\nNetId: 100\\n';;
esac
""")
        self.service.chmod(0o755)
        self.dumpsys.chmod(0o755)
        # Replace only the external Android executables in this disposable copy;
        # production has no environment-selected test implementation.
        cgi = self.mod / "webroot/cgi-bin/dns_cache.sh"
        source = cgi.read_text()
        for key, executable in [("DNS_SERVICE_BIN", self.service), ("DNS_DUMPSYS_BIN", self.dumpsys)]:
            original = f"{key}=/system/bin/{executable.name}"
            self.assertEqual(source.count(original), 1)
            source = source.replace(original, f"{key}={shlex.quote(str(executable))}")
        cgi.write_text(source)
        self.env = dict(os.environ, PIXEL9PRO_MODDIR=str(self.mod),
                        FIXTURE=str(self.work),
                        REQUEST_METHOD="POST", REMOTE_ADDR="127.0.0.1",
                        HTTP_X_PIXEL9PRO_TOKEN="fixture-dns-token", CONTENT_TYPE="application/json", CASE="ok")

    def tearDown(self):
        self.temp.cleanup()

    def run_cgi(self, case="ok", body=None, **env):
        content = json.dumps(body if body is not None else {"action": "clear"})
        config = dict(self.env, CASE=case, CONTENT_LENGTH=str(len(content.encode())), **env)
        proc = subprocess.run(["sh", str(self.mod / "webroot/cgi-bin/dns_cache.sh")],
                              input=content, capture_output=True, text=True, env=config, timeout=8)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        headers, payload = proc.stdout.split("\n\n", 1)
        calls = (self.work / "calls").read_text().splitlines() if (self.work / "calls").exists() else []
        return headers, json.loads(payload), calls

    def test_success_requires_all_networks_and_deduplicates(self):
        _, result, calls = self.run_cgi()
        self.assertEqual(calls, ["100", "105"])
        self.assertTrue(result["completed"])
        self.assertEqual(result["cleared_networks"], result["total_networks"])
        self.assertEqual(result["scope"], "system")

    def test_auth_and_schema_precede_system_calls(self):
        for env, body in [({"HTTP_X_PIXEL9PRO_TOKEN": "bad"}, None),
                          ({"REQUEST_METHOD": "GET"}, None), ({}, {"action": "clear", "net_id": 100})]:
            with self.subTest(env=env, body=body):
                _, result, calls = self.run_cgi(body=body, **env)
                self.assertFalse(result["ok"])
                self.assertEqual(calls, [])

    def test_capability_and_complete_network_listing_precede_flush(self):
        for case in ["version", "descriptor", "empty", "dump_timeout", "invalid_network"]:
            with self.subTest(case=case):
                _, result, calls = self.run_cgi(case)
                self.assertFalse(result["ok"])
                self.assertFalse(result["completed"])
                self.assertEqual(calls, [])

    def test_partial_completion_is_not_success(self):
        _, result, calls = self.run_cgi("partial")
        self.assertEqual(calls, ["100", "105"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["cleared_networks"], 1)
        self.assertEqual(result["total_networks"], 2)
        self.assertFalse(result["result_unconfirmed"])

    def test_binder_denial_is_not_process_success(self):
        _, result, calls = self.run_cgi("denied")
        self.assertEqual(calls, ["100"])
        self.assertEqual(result["error_code"], "DNS_CLEAR_DENIED")
        self.assertFalse(result["ok"])

    def test_unconfirmed_call_is_not_replayed(self):
        for case in ["timeout", "malformed"]:
            with self.subTest(case=case):
                (self.work / "calls").unlink(missing_ok=True)
                _, result, calls = self.run_cgi(case)
                self.assertEqual(calls, ["100"])
                self.assertTrue(result["result_unconfirmed"])
                self.assertFalse(result["completed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
