"""Host tests of real CGI reads; only Android command boundaries are mocked."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]


class CgiReadPathsTest(unittest.TestCase):
    def setUp(self):
        work = SOURCE.parent / "work"
        work.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="cgi-read-paths-", dir=work)
        self.root = Path(self.scratch.name)
        self.mod = self.root / "module"
        files = [
            "webroot/cgi-bin/_common.sh", "webroot/cgi-bin/optimize.sh",
            "webroot/cgi-bin/standby_guard.sh", "webroot/cgi-bin/profile.sh",
            "scripts/runtime_defaults_lib.sh", "scripts/background_tasks_lib.sh",
            "scripts/scheduler_detect_lib.sh", "scripts/scheduler_owner_lib.sh",
            "scripts/cpu_profile_lib.sh", "scripts/profile_state_lib.sh",
            "scripts/scheduler_boot_mode_lib.sh", "scripts/scheduler_transition_guard_lib.sh",
            "scripts/scheduler_capability_lib.sh", "scripts/scheduler_async_lib.sh",
            "scripts/state_io_lib.sh",
        ]
        for name in files:
            target = self.mod / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if os.environ.get("CGI_READ_TEST_REF") and name.startswith("webroot/cgi-bin/"):
                content = subprocess.run(["git", "-C", str(SOURCE), "show",
                                          f"{os.environ['CGI_READ_TEST_REF']}:{name}"],
                                         check=True, text=True, capture_output=True).stdout
            else:
                content = (SOURCE / name).read_text()
            target.write_text(content, encoding="utf-8")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.mock("settings", """#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_ROOT/settings.calls"
[ "$MOCK_SETTINGS_FAIL" != "$2" ] || exit 124
case "$1:$2" in
  list:global) printf 'mobile_data_always_on=1\nadaptive_connectivity_enabled=0\nnetwork_recommendations_enabled=1\nnearby_sharing_enabled=0\n' ;;
  list:secure) printf 'adaptive_connectivity_enabled=1\nadaptive_connectivity_wifi_enabled=1\n' ;;
  get:global)
    case "$3" in adaptive_connectivity_enabled|nearby_sharing_enabled) printf '0\n' ;;
      *) printf '1\n' ;; esac ;;
  get:secure) printf '1\n' ;;
  *) exit 64 ;;
esac
""")
        self.mock("ip", "#!/bin/sh\nprintf 'wlan0: <UP,MULTICAST>\\n'\n")
        self.mock("sed", """#!/bin/sh
for arg do
  case "$arg" in *.standby_diag_state|*.scheduler_health_state)
    printf '%s\n' "$arg" >> "$MOCK_ROOT/state.parsers" ;;
  esac
done
exec /usr/bin/sed "$@"
""")
        (self.mod / ".webui_token").write_text("fixture-token")
        (self.mod / ".idle_isolate_mode").write_text("on")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        PIXEL9PRO_MODDIR=str(self.mod), PIXEL9PRO_CGI_TEST_MODE="1",
                        PIXEL9PRO_ANDROID_SETTINGS=str(self.bin / "settings"),
                        MOCK_ROOT=str(self.root), MOCK_SETTINGS_FAIL="",
                        REQUEST_METHOD="GET", REMOTE_ADDR="127.0.0.1",
                        HTTP_X_PIXEL9PRO_TOKEN="fixture-token", QUERY_STRING="")

    def tearDown(self):
        self.scratch.cleanup()

    def mock(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def run_cgi(self, name):
        result = subprocess.run(["sh", str(self.mod / "webroot/cgi-bin" / name)],
                                env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        headers, body = result.stdout.split("\n\n", 1)
        return headers, json.loads(body)

    def test_optimize_batches_settings_and_preserves_fields(self):
        headers, payload = self.run_cgi("optimize.sh")
        self.assertNotIn("Status:", headers)
        self.assertEqual(payload["adaptive_connectivity"], "0")
        self.assertEqual(payload["mobile_data_always_on"], "1")
        self.assertEqual(payload["nearby_sharing"], "0")
        self.assertEqual(payload["multicast"], "on")
        self.assertEqual((self.root / "settings.calls").read_text().splitlines(),
                         ["list global", "list secure"])

    def test_optimize_does_not_return_success_on_settings_failure(self):
        self.env["MOCK_SETTINGS_FAIL"] = "global"
        headers, payload = self.run_cgi("optimize.sh")
        self.assertIn("Status: 503", headers)
        self.assertFalse(payload["ok"])
        self.assertIn("global", payload["error"])

    def test_optimize_reports_secure_namespace_failure(self):
        self.env["MOCK_SETTINGS_FAIL"] = "secure"
        headers, payload = self.run_cgi("optimize.sh")
        self.assertIn("Status: 503", headers)
        self.assertFalse(payload["ok"])
        self.assertIn("secure", payload["error"])

    def test_optimize_preserves_absent_and_empty_setting_values(self):
        self.mock("settings", """#!/bin/sh
case "$1" in
  list) printf 'mobile_data_always_on=\n' ;;
  get) [ "$3" = mobile_data_always_on ] && printf '\n' || printf 'null\n' ;;
esac
""")
        _, payload = self.run_cgi("optimize.sh")
        self.assertEqual(payload["mobile_data_always_on"], "")
        self.assertEqual(payload["nearby_sharing"], "null")

    def test_standby_reads_one_snapshot_without_per_field_processes(self):
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        (self.mod / ".background_run").write_text("test-worker")
        (self.mod / ".standby_diag_state").write_text(
            f"boot_id={boot}\nworker_id=test-worker\nupdated_at=123\nscreen=on\n"
            "worker_mode=active\nnext_sleep_secs=60\nburst_active=1\nnr_switch=off\n"
            "nr_state=nr\nprofile_policy=manual\nactive_profile=balanced\ncycle_count=7")
        _, payload = self.run_cgi("standby_guard.sh")
        self.assertEqual(payload["diag_updated_at"], "123")
        self.assertEqual(payload["diag_screen"], "on")
        self.assertEqual(payload["diag_cycle_count"], "7")
        self.assertFalse((self.root / "state.parsers").exists(), "per-field file parser used")

    def test_standby_rejects_previous_boot_snapshot(self):
        (self.mod / ".background_run").write_text("test-worker")
        (self.mod / ".standby_diag_state").write_text(
            "boot_id=old-boot\nworker_id=test-worker\nscreen=on\ncycle_count=7")
        _, payload = self.run_cgi("standby_guard.sh")
        self.assertEqual(payload["diag_screen"], "unknown")
        self.assertEqual(payload["diag_cycle_count"], "0")

    def test_profile_health_reads_one_snapshot_without_per_field_processes(self):
        self.env["QUERY_STRING"] = "compact=1"
        (self.mod / ".scheduler_health_state").write_text(
            "status=healthy\nreason=verified\nchecked_epoch=123\nprofile_verified=yes\n"
            "cpufreq_permissions=ok\npowerhal_failures=0")
        _, payload = self.run_cgi("profile.sh")
        self.assertEqual(payload["scheduler_health"], dict(status="healthy", reason="verified",
                         checked_epoch="123", profile_verified="yes", cpufreq_permissions="ok",
                         powerhal_failures="0"))
        self.assertFalse((self.root / "state.parsers").exists(), "per-field file parser used")

    def test_profile_health_preserves_crlf_state(self):
        self.env["QUERY_STRING"] = "compact=1"
        (self.mod / ".scheduler_health_state").write_bytes(
            b"status=healthy\r\nreason=verified\r\nchecked_epoch=123\r\nprofile_verified=yes\r\n"
            b"cpufreq_permissions=ok\r\npowerhal_failures=0\r\n")
        _, payload = self.run_cgi("profile.sh")
        self.assertEqual(payload["scheduler_health"]["status"], "healthy")
        self.assertEqual(payload["scheduler_health"]["powerhal_failures"], "0")

    def test_shell_syntax(self):
        for path in self.mod.rglob("*.sh"):
            with self.subTest(path=path.relative_to(self.mod)):
                result = subprocess.run(["sh", "-n", str(path)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
