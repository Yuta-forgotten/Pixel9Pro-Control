"""Run the production BG table/observation helpers; no Android commands."""
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
SCRIPT = r'''
set -eu
MODDIR="$1"
. "$MODDIR/scripts/bg_restrict_lib.sh"
_bg_apply_pkg=caller-package
_bg_target_bucket=caller-bucket
_bg_target_bg=caller-bg
_bg_target_any=caller-any
_bgt_file=caller-file; _bgt_key=caller-key; _bgt_row=caller-row; _bgt_tmp=caller-tmp
_sio_path=caller-path; _sio_source=caller-source; _sio_mode=caller-mode; _sio_tmp=caller-sio
tmp=caller-generic
umask 027
trap ': caller-trap' EXIT
caller_traps=$(trap)
set -- caller-first 'caller second'
bg_table_replace "$MODDIR/table" com.example.one 'com.example.one|first'
bg_table_replace "$MODDIR/table" com.example.two 'com.example.two|second'
bg_table_replace "$MODDIR/table" com.example.one 'com.example.one|updated'
[ "$(wc -l < "$MODDIR/table")" -eq 2 ]
grep -Fx 'com.example.one|updated' "$MODDIR/table" >/dev/null
bg_record_observation com.example.one rare ignore allow
[ "$_bgo_pkg" = com.example.one ] # Explicit owned output; not a local variable.
grep -F 'com.example.one|rare|ignore|allow|' "$MODDIR/.bg_restrict_observed" >/dev/null
[ "$_bg_apply_pkg:$_bg_target_bucket:$_bg_target_bg:$_bg_target_any" = caller-package:caller-bucket:caller-bg:caller-any ]
[ "$_bgt_file:$_bgt_key:$_bgt_row:$_bgt_tmp" = caller-file:caller-key:caller-row:caller-tmp ]
[ "$_sio_path:$_sio_source:$_sio_mode:$_sio_tmp" = caller-path:caller-source:caller-mode:caller-sio ]
[ "$tmp" = caller-generic ] || { printf 'caller tmp was overwritten\n' >&2; exit 77; }
[ "$1:$2:$#" = 'caller-first:caller second:2' ]
[ "$(umask)" = 0027 ]
[ "$(trap)" = "$caller_traps" ]
! command -v state_read_entry >/dev/null
[ "$(stat -c %a "$MODDIR/table")" = 600 ]
[ "$(stat -c %a "$MODDIR/.bg_restrict_observed")" = 600 ]
# The baseline helper deliberately imports the same function definitions in
# its caller. Their file IO still uses subshell scratch, not caller state.
bg_record_baseline com.example.one 10 allow allow
command -v state_read_entry >/dev/null
grep -Fx 'com.example.one|10|allow|allow' "$BG_BASELINE_FILE" >/dev/null
[ "$_bg_apply_pkg:$_bg_target_bucket:$_bg_target_bg:$_bg_target_any" = caller-package:caller-bucket:caller-bg:caller-any ]
[ "$_bgt_file:$_bgt_key:$_bgt_row:$_bgt_tmp" = caller-file:caller-key:caller-row:caller-tmp ]
[ "$_sio_path:$_sio_source:$_sio_mode:$_sio_tmp" = caller-path:caller-source:caller-mode:caller-sio ]
[ "$(trap)" = "$caller_traps" ] && [ "$(umask)" = 0027 ]
# A rejected real write must not leak traps, scratch or the failed row.
mkdir "$MODDIR/directory-target"
if bg_table_replace "$MODDIR/directory-target" com.example.one bad; then exit 78; fi
[ "$_bgt_file" = caller-file ] && [ "$_sio_path" = caller-path ]
[ "$(trap)" = "$caller_traps" ]
printf 'Production BG helpers preserve caller variables, arguments, traps, umask and source scope\n'
'''


class BackgroundNamespaceTest(unittest.TestCase):
    def test_real_helpers_and_counterexample(self):
        work = SOURCE.parent / "work"
        with tempfile.TemporaryDirectory(prefix="bg-namespace-", dir=work) as temporary:
            root = Path(temporary)
            self.assertEqual(root.resolve().parent, work.resolve())
            self.assertTrue(root.name.startswith("bg-namespace-"))
            subprocess.run(["mount", "-t", "tmpfs", "-o", "size=2m,mode=700", "tmpfs", str(root)], check=True)
            try:
                subprocess.run(["mountpoint", "-q", str(root)], check=True)
                self.assertEqual(subprocess.check_output(["stat", "-f", "-c", "%T", str(root)], text=True).strip(), "tmpfs")
                scripts = root / "scripts"
                scripts.mkdir()
                for name in ("bg_restrict_lib.sh", "state_io_lib.sh"):
                    (scripts / name).write_bytes((SOURCE / "scripts" / name).read_bytes())
                actual = subprocess.run(["sh", "-s", "--", str(root)], input=SCRIPT, text=True, capture_output=True, timeout=10)
                self.assertEqual(actual.returncode, 0, actual.stdout + actual.stderr)
                # Prove the caller-preservation check detects a real global
                # clobber, not merely a statically disallowed spelling.
                bad = SCRIPT.replace("tmp=caller-generic", 'tmp=caller-generic\nbg_record_observation() { _bgo_pkg="$1"; tmp=unsafe; }')
                negative = subprocess.run(["sh", "-s", "--", str(root)], input=bad, text=True, capture_output=True, timeout=10)
                self.assertEqual(negative.returncode, 77, negative.stdout + negative.stderr)
                self.assertIn("caller tmp was overwritten", negative.stderr)
                print(actual.stdout.strip())
            finally:
                subprocess.run(["umount", str(root)], check=True)
                self.assertNotEqual(subprocess.run(["mountpoint", "-q", str(root)]).returncode, 0)
                self.assertEqual(list(root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
