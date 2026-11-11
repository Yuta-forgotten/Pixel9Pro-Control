"""Real CGI -> detached worker -> receipt tests, with Android boundaries mocked."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1]
PACKAGE = "com.example.fixture"

MOCKS = r'''
bg_test_call() { printf '%s\n' "$*" >> "$MOCK_ROOT/calls"; }
bg_package_presence() { bg_test_call presence; return 0; }
bg_am() {
    bg_test_call "am $1"
    case "$1" in
        get-standby-bucket)
            _mock_wait=0
            while [ -f "$MOCK_ROOT/hold" ] && [ "$_mock_wait" -lt 250 ]; do
                sleep 0.02; _mock_wait=$((_mock_wait+1))
            done
            cat "$MOCK_ROOT/bucket" ;;
        set-standby-bucket)
            [ ! -f "$MOCK_ROOT/fail_all" ] || return 1
            case "$5" in active) _mock_bucket=10 ;; rare) _mock_bucket=40 ;;
                restricted) _mock_bucket=45 ;; *) _mock_bucket="$5" ;; esac
            printf '%s' "$_mock_bucket" > "$MOCK_ROOT/bucket" ;;
        *) return 64 ;;
    esac
}
bg_cmd() {
    bg_test_call "cmd $2 $6"
    case "$2" in
        get) printf '%s: %s\n' "$6" "$(cat "$MOCK_ROOT/$6")" ;;
        set)
            [ ! -f "$MOCK_ROOT/fail_all" ] || return 1
            if [ -f "$MOCK_ROOT/fail_apply" ] && [ "$6:$7" = RUN_ANY_IN_BACKGROUND:ignore ]; then
                rm "$MOCK_ROOT/fail_apply"; return 1
            fi
            printf '%s' "$7" > "$MOCK_ROOT/$6" ;;
        *) return 64 ;;
    esac
}
'''


class BackgroundRequestTest(unittest.TestCase):
    def setUp(self):
        work = SOURCE.parent / "work"
        work.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="bg-request-", dir=work)
        self.root = Path(self.scratch.name)
        self.mounted = False
        if os.environ.get("BG_REQUEST_TEST_TMPFS") == "1":
            self.assertEqual(self.root.resolve().parent, work.resolve())
            self.assertTrue(self.root.name.startswith("bg-request-"))
            subprocess.run(["mount", "-t", "tmpfs", "-o", "size=8m,mode=700", "tmpfs",
                            str(self.root)], check=True, capture_output=True, text=True)
            self.mounted = True
            subprocess.run(["mountpoint", "-q", str(self.root)], check=True)
            self.assertEqual(subprocess.check_output(["stat", "-f", "-c", "%T", str(self.root)],
                                                    text=True).strip(), "tmpfs")
        self.mod = self.root / "module"
        for name in ("webroot/cgi-bin/_common.sh", "webroot/cgi-bin/bg_restrict.sh",
                     "scripts/bg_restrict_lib.sh", "scripts/bg_transaction_lib.sh",
                     "scripts/state_io_lib.sh", "scripts/background_tasks_lib.sh",
                     "scripts/app_identity_lib.sh", "scripts/audit_log_lib.sh",
                     "scripts/install_state_lib.sh"):
            target = self.mod / name
            target.parent.mkdir(parents=True, exist_ok=True)
            content = (SOURCE / name).read_text()
            if name == "scripts/bg_restrict_lib.sh":
                content += MOCKS
            if name == "scripts/bg_transaction_lib.sh":
                content = content.replace("bg_tx_clear() {", "test_actual_bg_tx_clear() {")
                content = content.replace("bg_tx_commit() {", "test_actual_bg_tx_commit() {")
                content += r'''
bg_tx_clear() {
    if bg_tx_cleanup_only; then
        _mock_cleanup_wait=0
        while [ -f "$MOCK_ROOT/hold_cleanup" ] && [ "$_mock_cleanup_wait" -lt 250 ]; do
            : > "$MOCK_ROOT/cleanup_entered"
            sleep 0.02; _mock_cleanup_wait=$((_mock_cleanup_wait+1))
        done
        [ ! -f "$MOCK_ROOT/fail_cleanup" ] || return 1
        if [ -f "$MOCK_ROOT/fail_partial_cleanup" ]; then
            rm -f "$BG_TX_ROOT/runtime" "$BG_TX_ROOT/phase" "$BG_TX_ROOT/operation_id"
            return 1
        fi
    fi
    test_actual_bg_tx_clear "$@"
}
bg_tx_commit() {
    test_actual_bg_tx_commit "$@" || return $?
    [ ! -f "$MOCK_ROOT/signal_after_commit" ] || kill -TERM "$$"
}
'''
            if name == "scripts/state_io_lib.sh":
                content = content.replace("state_atomic_write() (", "test_actual_atomic_write() (")
                content += r'''
state_atomic_write() {
    if [ "$1" = "$MODDIR/.bg_operation" ] && [ -f "$MOCK_ROOT/fail_terminal" ]; then
        case "$2" in *'phase=success'*) return 1 ;; esac
    fi
    test_actual_atomic_write "$@"
}
'''
            target.write_text(content)
        (self.mod / ".webui_token").write_text("fixture-token")
        (self.mod / ".bg_restrict_enabled").write_text("on")
        (self.mod / ".bg_restrict_list").write_text(f"{PACKAGE}|bucket|5\n")
        (self.root / "bucket").write_text("10")
        for op in ("RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND"):
            (self.root / op).write_text("allow")
        self.env = dict(os.environ, PIXEL9PRO_MODDIR=str(self.mod),
                        PIXEL9PRO_AUDIT_LOG_DIR=str(self.root / "audit"),
                        MOCK_ROOT=str(self.root), REMOTE_ADDR="127.0.0.1",
                        HTTP_X_PIXEL9PRO_TOKEN="fixture-token", QUERY_STRING="")

    def tearDown(self):
        (self.root / "hold").unlink(missing_ok=True)
        (self.root / "hold_cleanup").unlink(missing_ok=True)
        # The finite audit child closes its own writer lock after publication.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            receipt = self.mod / ".bg_operation"
            if receipt.exists() and any(f"phase={p}\n" in receipt.read_text() for p in ("queued", "running")):
                time.sleep(0.05)
                continue
            events = self.root / "audit/events.log"
            if events.exists() and not (self.root / "audit/.writer.lock").exists():
                break
            time.sleep(0.05)
        if self.mounted:
            subprocess.run(["umount", str(self.root)], check=True, capture_output=True, text=True)
            self.assertNotEqual(subprocess.run(["mountpoint", "-q", str(self.root)]).returncode, 0)
            self.assertEqual(list(self.root.iterdir()), [], "underlying project directory has survivors")
        self.scratch.cleanup()

    def cgi(self, body=None, extra_env=None):
        payload = "" if body is None else json.dumps(body)
        env = dict(self.env, REQUEST_METHOD="GET" if body is None else "POST",
                   CONTENT_TYPE="application/json", CONTENT_LENGTH=str(len(payload)))
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(["sh", str(self.mod / "webroot/cgi-bin/bg_restrict.sh")],
                                input=payload, env=env, text=True, capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        headers, text = result.stdout.split("\n\n", 1)
        return headers, json.loads(text)

    def update(self):
        return self.cgi(dict(action="update", package=PACKAGE, policy="block_all", delay=5))

    def terminal(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            headers, data = self.cgi()
            if "Status: 409" in headers and data.get("error_code") == "BG_POLICY_BUSY":
                time.sleep(0.05)
                continue
            if not data.get("state_pending"):
                return data
            time.sleep(0.05)
        self.fail("worker did not reach a terminal state")

    def test_accepted_pending_conflict_then_committed(self):
        (self.root / "hold").touch()
        started = time.monotonic()
        _, accepted = self.update()
        self.assertLess(time.monotonic() - started, 2, "POST waited for the worker's Binder calls")
        self.assertTrue(accepted["accepted"])
        self.assertFalse(accepted["final"])
        _, pending = self.cgi()
        self.assertTrue(pending["state_pending"])
        self.assertTrue(pending["operation"]["pending"])
        self.assertNotIn("packages", pending, "pending response exposed a partial policy snapshot")
        headers, conflict = self.update()
        self.assertIn("Status: 409", headers)
        self.assertEqual(conflict["error_code"], "BG_OPERATION_BUSY")
        (self.root / "hold").unlink()
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "success")
        self.assertTrue(done["operation"]["committed"])
        self.assertFalse(done["recovery_required"])
        self.assertFalse((self.mod / ".locks/bg_operation.lock").exists())
        self.assertEqual(done["packages"][0]["policy"], "block_all")
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 10)
        self.assertEqual((self.mod / ".bg_restrict_observed").read_text().split("|")[1:4],
                         ["restricted", "ignore", "ignore"])

    def test_apply_failure_restores_entry_state(self):
        (self.root / "fail_apply").touch()
        self.update()
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "failed")
        self.assertEqual(done["operation"]["error_code"], "BG_APPLY_FAILED")
        self.assertEqual(done["operation"]["rollback"], "complete")
        self.assertFalse(done["operation"]["committed"])
        self.assertEqual((self.root / "bucket").read_text(), "10")
        self.assertEqual((self.root / "RUN_IN_BACKGROUND").read_text(), "allow")
        self.assertEqual(done["packages"][0]["policy"], "bucket")
        self.assertFalse(done["recovery_required"])

    def test_incomplete_rollback_is_recoverable_not_success(self):
        (self.root / "fail_all").touch()
        self.update()
        failed = self.terminal()
        self.assertEqual(failed["operation"]["rollback"], "incomplete")
        self.assertTrue(failed["recovery_required"])
        previous = (self.mod / ".bg_operation").read_text()
        headers, refused = self.update()
        self.assertIn("Status: 409", headers)
        self.assertEqual(refused["error_code"], "BG_RECOVERY_REQUIRED")
        self.assertEqual((self.mod / ".bg_operation").read_text(), previous)
        (self.root / "fail_all").unlink()
        _, accepted = self.cgi(dict(action="recover"))
        self.assertTrue(accepted["accepted"])
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "success")
        self.assertFalse(done["recovery_required"])
        self.assertEqual((self.root / "bucket").read_text(), "10")

    def test_dead_worker_requires_explicit_recovery(self):
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        (self.mod / ".bg_operation").write_text(
            f"id=test-job\nboot={boot}\nphase=running\ncommitted=false\nstart=1\naction=update")
        _, data = self.cgi()
        self.assertEqual(data["operation"]["phase"], "unconfirmed")
        self.assertNotIn("packages", data)
        headers, error = self.update()
        self.assertIn("Status: 409", headers)
        self.assertEqual(error["error_code"], "BG_RECOVERY_REQUIRED")
        self.cgi(dict(action="recover"))
        self.assertEqual(self.terminal()["operation"]["phase"], "success")

    def test_invalid_input_never_starts_worker(self):
        headers, error = self.cgi(dict(action="update", package=PACKAGE, policy="block_all", delay=4))
        self.assertIn("Status: 400", headers)
        self.assertEqual(error["error_code"], "BG_INVALID_DELAY")
        self.assertFalse((self.mod / ".bg_operation").exists())
        self.assertFalse((self.root / "calls").exists())

    def test_private_worker_rejects_mismatched_receipt(self):
        result = subprocess.run(["sh", str(self.mod / "webroot/cgi-bin/bg_restrict.sh")],
                                env=dict(self.env, PIXEL9PRO_BG_WORKER_ID="not-an-accepted-job"),
                                text=True, capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())

    def test_terminal_receipt_failure_retains_committed_restoration_snapshot(self):
        (self.root / "fail_terminal").touch()
        self.update()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            _, data = self.cgi()
            if data["operation"]["phase"] == "unconfirmed":
                break
            time.sleep(0.05)
        self.assertEqual(data["operation"]["phase"], "unconfirmed")
        self.assertEqual((self.mod / ".bg_policy_tx/phase").read_text(), "committed")
        self.assertEqual((self.root / "bucket").read_text(), "45")
        (self.root / "fail_terminal").unlink()
        self.cgi(dict(action="recover"))
        recovered = self.terminal()
        self.assertEqual(recovered["operation"]["phase"], "success")
        self.assertEqual((self.root / "bucket").read_text(), "10")
        self.assertEqual(recovered["packages"][0]["policy"], "bucket")
        self.assertFalse(recovered["recovery_required"])

    def test_queued_operation_blocks_upgrade_before_transaction_journal_exists(self):
        lock = self.mod / ".locks/bg_operation.lock"
        lock.mkdir(parents=True)
        (self.mod / ".bg_operation").write_text("id=fixture\nphase=queued\n")
        destination = self.root / "upgrade"
        destination.mkdir()
        script = '. "$1/scripts/install_state_lib.sh"; install_state_migrate "$1" "$2"'
        result = subprocess.run(["sh", "-c", script, "fixture", str(self.mod), str(destination)],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.mod / ".bg_policy_tx").exists())
        self.assertEqual(list(destination.iterdir()), [])
        (self.mod / ".bg_operation").unlink()

    def test_changed_shell_syntax(self):
        for path in self.mod.rglob("*.sh"):
            with self.subTest(file=path.relative_to(self.mod)):
                result = subprocess.run(["sh", "-n", str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_terminal_publication_and_cleanup_share_the_policy_lock(self):
        (self.root / "hold_cleanup").touch()
        self.update()
        deadline = time.monotonic() + 5
        while not (self.root / "cleanup_entered").exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((self.root / "cleanup_entered").exists())
        self.assertIn("phase=success\n", (self.mod / ".bg_operation").read_text())
        headers, data = self.cgi()
        self.assertIn("Status: 409", headers)
        self.assertEqual(data["error_code"], "BG_POLICY_BUSY")
        self.assertNotIn("recovery_required", data)
        (self.root / "hold_cleanup").unlink()
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "success")
        self.assertFalse(done["recovery_required"])

    def assert_cleanup_failure_never_undoes_published_success(self, flag):
        (self.root / flag).touch()
        self.update()
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "success")
        self.assertTrue(done["operation"]["committed"])
        self.assertFalse(done["recovery_required"])
        self.assertEqual((self.root / "bucket").read_text(), "45")
        published = (self.mod / ".bg_operation").read_text()
        headers, rejected = self.cgi(dict(action="recover"))
        self.assertIn("Status: 409", headers)
        self.assertEqual(rejected["error_code"], "BG_CLEANUP_PENDING")
        self.assertEqual((self.mod / ".bg_operation").read_text(), published)
        (self.root / flag).unlink()
        self.cgi(dict(action="recover"))
        recovered = self.terminal()
        self.assertEqual(recovered["operation"]["phase"], "success")
        self.assertFalse(recovered["recovery_required"])
        self.assertEqual((self.root / "bucket").read_text(), "45")
        self.assertEqual((self.root / "RUN_IN_BACKGROUND").read_text(), "ignore")
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 10,
                         "cleanup-only recovery issued Android writes or rollback")

    def test_cleanup_failure_never_undoes_published_success(self):
        self.assert_cleanup_failure_never_undoes_published_success("fail_cleanup")

    def test_partial_cleanup_failure_never_undoes_published_success(self):
        self.assert_cleanup_failure_never_undoes_published_success("fail_partial_cleanup")

    def test_signal_after_commit_rolls_back_before_publishing_failure(self):
        (self.root / "signal_after_commit").touch()
        self.update()
        done = self.terminal()
        self.assertEqual(done["operation"]["phase"], "failed")
        self.assertFalse(done["operation"]["committed"])
        self.assertEqual(done["operation"]["error_code"], "BG_WORKER_INTERRUPTED")
        self.assertEqual(done["operation"]["rollback"], "complete")
        self.assertEqual((self.root / "bucket").read_text(), "10")
        self.assertEqual((self.root / "RUN_IN_BACKGROUND").read_text(), "allow")
        self.assertEqual(done["packages"][0]["policy"], "bucket")
        self.assertFalse(done["recovery_required"])


if __name__ == "__main__":
    unittest.main()
