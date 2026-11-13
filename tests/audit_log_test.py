"""Focused host tests of the real audit library/CGI; no device commands."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]


class AuditLogTest(unittest.TestCase):
    def setUp(self):
        work = SOURCE.parent / "work"
        work.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix="audit-log-test-", dir=work)
        self.root = Path(self.scratch.name)
        self.mod = self.root / "module"
        for name in ("scripts/audit_log_lib.sh", "webroot/cgi-bin/audit_log.sh", "webroot/cgi-bin/auth.sh",
                     "webroot/cgi-bin/_common.sh"):
            target = self.mod / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, target)
        (self.mod / ".webui_token").write_text("fixture-token", encoding="ascii")
        (self.mod / "module.prop").write_text("version=fixture\n", encoding="ascii")
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.env = dict(os.environ, PIXEL9PRO_MODDIR=str(self.mod),
                        PIXEL9PRO_AUDIT_LOG_DIR=str(self.logs),
                        PIXEL9PRO_AUDIT_LOG_MAX_BYTES="4096",
                        PIXEL9PRO_AUDIT_LOG_KEEP="3",
                        REMOTE_ADDR="127.0.0.1", REQUEST_METHOD="GET",
                        HTTP_X_PIXEL9PRO_TOKEN="fixture-token", QUERY_STRING="")
        self.lib = self.mod / "scripts/audit_log_lib.sh"
        self.cgi = self.mod / "webroot/cgi-bin/audit_log.sh"

    def tearDown(self):
        self.scratch.cleanup()

    def library(self, *args):
        return subprocess.run(
            ["sh", "-c", '. "$1"; audit_log_init "$2" || exit; shift 2; "$@"',
             "audit-test", str(self.lib), str(self.mod), *map(str, args)],
            env=self.env, text=True, capture_output=True, timeout=20)

    def request(self, query="", **env):
        result = subprocess.run(["sh", str(self.cgi)], env=dict(self.env, QUERY_STRING=query, **env),
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        headers, body = result.stdout.split("\n\n", 1)
        self.assertLess(len(body.encode()), 4 * 1024 * 1024)
        return headers, json.loads(body)

    def write_lines(self, name, lines):
        (self.logs / name).write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")

    def file_state(self):
        return {p.name: (hashlib.sha256(p.read_bytes()).hexdigest(), p.stat().st_mtime_ns)
                for p in self.logs.iterdir() if p.is_file() and p.name != ".writer.flock"}

    def test_reads_preserve_all_history_and_date_marker(self):
        for day in range(1, 7):
            self.write_lines(f"events-2025-01-{day:02}.log", [f"old-{day}"])
        self.write_lines("events.log.1", ["rotated"])
        self.write_lines("events.log", ["current"])
        self.write_lines(".events_day", ["2025-01-01"])
        before = self.file_state()
        for _ in range(2):
            headers, page = self.request("all=1&limit=3")
            self.assertNotIn("Status:", headers)
            self.assertEqual(page["lines"], ["old-1", "old-2", "old-3"])
            self.assertEqual(page["total_lines"], 8)
            self.assertTrue(page["rotated"])
        self.assertEqual(self.file_state(), before)
        self.assertEqual(set(p.name for p in self.logs.iterdir()), set(before) | {".writer.flock"})
        self.assertEqual((self.logs / ".writer.flock").stat().st_size, 0)
        _, current = self.request()
        self.assertEqual(current["lines"], ["current"])
        self.assertTrue(current["rotated"])

    def test_empty_read_does_not_create_log_or_date(self):
        headers, page = self.request()
        self.assertNotIn("Status:", headers)
        self.assertEqual(page["lines"], [])
        self.assertEqual(page["total_lines"], 0)
        self.assertIsNone(page["next_offset"])
        self.assertTrue(page["complete"])
        self.assertFalse(page["truncated"])
        self.assertEqual([p.name for p in self.logs.iterdir()], [".writer.flock"])
        self.assertEqual((self.logs / ".writer.flock").stat().st_size, 0)

    def test_pages_cover_archive_and_current_once(self):
        expected = [f"line-{i}" for i in range(1203)]
        self.write_lines("events-2025-01-01.log", expected[:400])
        self.write_lines("events.log.2", expected[400:601])
        self.write_lines("events.log.1", expected[601:900])
        self.write_lines("events.log", expected[900:])
        actual, offset, snapshot = [], 0, ""
        while True:
            query = f"all=1&limit=500&offset={offset}"
            if snapshot:
                query += f"&snapshot_id={snapshot}"
            headers, page = self.request(query)
            self.assertNotIn("Status:", headers)
            snapshot = snapshot or page["snapshot_id"]
            self.assertEqual(page["snapshot_id"], snapshot)
            self.assertEqual(page["total_lines"], len(expected))
            self.assertEqual(page["offset"], offset)
            self.assertLessEqual(len(page["lines"]), 500)
            actual.extend(page["lines"])
            if page["complete"]:
                self.assertIsNone(page["next_offset"])
                self.assertFalse(page["truncated"])
                break
            self.assertTrue(page["truncated"])
            self.assertEqual(page["next_offset"], offset + len(page["lines"]))
            offset = page["next_offset"]
        self.assertEqual(actual, expected)

    def test_snapshot_detects_same_size_same_mtime_rewrite(self):
        self.write_lines("events.log", ["aaaa", "tail"])
        _, first = self.request("limit=1")
        path = self.logs / "events.log"
        before = path.stat()
        self.write_lines("events.log", ["bbbb", "tail"])
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        headers, page = self.request(f"limit=1&offset=1&snapshot_id={first['snapshot_id']}")
        self.assertIn("Status: 409", headers)
        self.assertEqual(page["error_code"], "AUDIT_SNAPSHOT_CHANGED")
        self.assertNotIn("lines", page)

    def test_invalid_query_rejected_without_log_write(self):
        self.write_lines("events.log", ["preserve"])
        before = self.file_state()
        for query in ("limit=0", "limit=501", "limit=-1", "limit=2&limit=3",
                      "all=1&offset=-1", "all=2", "offset=2147483648",
                      "snapshot_id=../../outside", "path=events.log", "limit=1&",
                      "limit=1\noffset=0",
                      "limit=1%26offset=0", "snapshot_id=" + "A" * 64,
                      "x=" + "a" * 256):
            with self.subTest(query=query):
                headers, page = self.request(query)
                self.assertIn("Status: 400", headers)
                self.assertFalse(page["ok"])
        self.assertEqual(self.file_state(), before)
        headers, page = self.request("offset=2")
        self.assertIn("Status: 400", headers)
        self.assertEqual(page["error_code"], "AUDIT_OFFSET_INVALID")

    def test_token_boundary_rejects_without_reading(self):
        self.write_lines("events.log", ["private"])
        headers, page = self.request("all=1", HTTP_X_PIXEL9PRO_TOKEN="wrong")
        self.assertIn("Status: 403", headers)
        self.assertFalse(page["ok"])
        self.assertNotIn("private", json.dumps(page))

    def test_read_failure_does_not_record_its_own_error(self):
        target = self.root / "outside"
        target.write_text("untouched", encoding="ascii")
        (self.logs / "events.log").symlink_to(target)
        before = set(p.name for p in self.logs.iterdir())
        headers, page = self.request()
        self.assertIn("Status: 503", headers)
        self.assertFalse(page["ok"])
        self.assertEqual(set(p.name for p in self.logs.iterdir()), before | {".writer.flock"})
        self.assertEqual(target.read_text(), "untouched")

    def test_authenticated_get_503_does_not_persist(self):
        common = self.mod / "webroot/cgi-bin/_common.sh"
        result = subprocess.run(
            ["sh", "-c", '. "$1"; require_loopback; json_error "503 Service Unavailable" "fixture"',
             "audit-test", str(common)], env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Status: 503", result.stdout)
        self.assertEqual(list(self.logs.iterdir()), [])

    def test_authentication_boundary_bad_json_does_not_persist(self):
        body = "{broken"
        env = dict(self.env, REQUEST_METHOD="POST", HTTP_HOST="127.0.0.1:6210",
                   HTTP_ORIGIN="http://127.0.0.1:6210", HTTP_X_PIXEL9PRO_BOOTSTRAP="1",
                   CONTENT_TYPE="application/json", CONTENT_LENGTH=str(len(body)))
        result = subprocess.run(["sh", str(self.mod / "webroot/cgi-bin/auth.sh")],
                                input=body, env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Status: 400", result.stdout)
        self.assertEqual(list(self.logs.iterdir()), [])

    def test_json_escaping_preserves_records(self):
        expected = ['quote" backslash\\ tab\t control\x01', "中文日志"]
        self.write_lines("events.log", expected)
        headers, page = self.request()
        self.assertNotIn("Status:", headers)
        self.assertEqual(page["lines"], expected)

    def test_oversized_record_is_explicit_not_silently_cut(self):
        self.write_lines("events.log", ["a" * 1601])
        headers, page = self.request()
        self.assertIn("Status: 422", headers)
        self.assertEqual(page["error_code"], "AUDIT_LOG_INTEGRITY")
        self.assertNotIn("lines", page)
        self.write_lines("events.log", ["\x01" * 1200] * 500)
        headers, page = self.request("limit=500")
        self.assertIn("Status: 422", headers)
        self.assertEqual(page["error_code"], "AUDIT_LOG_INTEGRITY")

    def test_fixed_sources_reject_symlinks_and_ignore_unknown_files(self):
        secret = self.root / "outside"
        secret.write_text("private-target", encoding="ascii")
        self.write_lines("events.log", ["owned"])
        self.write_lines("not-ours.log", ["unknown"])
        _, page = self.request("all=1")
        self.assertEqual(page["lines"], ["owned"])
        (self.logs / "events-2025-01-01.log").symlink_to(secret)
        headers, page = self.request("all=1")
        self.assertIn("Status: 503", headers)
        self.assertNotIn("private-target", json.dumps(page))
        self.assertEqual(secret.read_text(), "private-target")

    def test_flock_preserves_legacy_lock_and_rejects_symlink(self):
        legacy = self.logs / ".writer.lock"
        legacy.mkdir()
        (legacy / "pid").write_text("old-owner\n", encoding="ascii")
        self.write_lines("events.log", ["owned"])
        headers, page = self.request()
        self.assertNotIn("Status:", headers)
        self.assertEqual(page["lines"], ["owned"])
        self.assertEqual((legacy / "pid").read_text(), "old-owner\n")
        lock = self.logs / ".writer.flock"
        before = (lock.stat().st_size, lock.stat().st_mtime_ns)
        self.request()
        self.assertEqual((lock.stat().st_size, lock.stat().st_mtime_ns), before)
        lock.unlink()
        outside = self.root / "outside-lock"
        outside.write_text("preserve-lock-target", encoding="ascii")
        lock.symlink_to(outside)
        headers, page = self.request()
        self.assertIn("Status: 503", headers)
        self.assertFalse(page["ok"])
        self.assertEqual(outside.read_text(), "preserve-lock-target")

    def test_size_rotation_preserves_legacy_and_date(self):
        self.write_lines(".events_day", ["2025-01-01"])
        self.write_lines("events-2025-01-01.log", ["legacy"])
        self.write_lines("events.log.3", ["oldest"])
        self.write_lines("events.log.2", ["middle"])
        self.write_lines("events.log.1", ["recent"])
        (self.logs / "events.log").write_text("x" * 4095, encoding="ascii")
        keep = {name: self.file_state()[name] for name in (".events_day", "events-2025-01-01.log")}
        result = self.library("audit_log_event", "cgi", "first", "success", "OK", 7)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.logs / "events.log.1").read_text(), "recent\n")
        result = self.library("audit_log_event", "cgi", "second", "failure", "FAILED", 8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.logs / "events.log.3").read_text(), "middle\n")
        self.assertEqual((self.logs / "events.log.2").read_text(), "recent\n")
        self.assertIn("operation=first", (self.logs / "events.log.1").read_text())
        current = (self.logs / "events.log").read_text()
        self.assertIn("schema=2", current)
        self.assertIn("operation=second", current)
        self.assertIn("duration_ms=8", current)
        self.assertEqual({name: self.file_state()[name] for name in keep}, keep)

    def test_existing_text_tail_abi_and_concurrent_reads_writes(self):
        self.write_lines("events.log", ["seed"])
        result = self.library("audit_log_read", 1, 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "seed\n")
        def task(index):
            if index % 2:
                result = self.library("audit_log_event", "cgi", f"op{index}", "success", "OK", 0)
                self.assertEqual(result.returncode, 0, result.stderr)
            else:
                result = subprocess.run(["sh", "-x", str(self.cgi)],
                                        env=dict(self.env, QUERY_STRING="all=1&limit=500"),
                                        text=True, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                headers, body = result.stdout.split("\n\n", 1)
                page = json.loads(body)
                self.assertNotIn("Status:", headers, result.stderr)
                self.assertEqual(page["total_lines"], len(page["lines"]))
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(task, range(12)))
        _, page = self.request("all=1&limit=500")
        self.assertEqual(page["total_lines"], 7)
        for index in range(1, 12, 2):
            self.assertEqual(sum(f"operation=op{index} " in line for line in page["lines"]), 1)
        self.assertFalse((self.logs / ".writer.lock").exists())
        released = subprocess.run(["flock", "-n", str(self.logs / ".writer.flock"), "true"],
                                  text=True, capture_output=True, timeout=10)
        self.assertEqual(released.returncode, 0, released.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
