"""Run the actual installer from an empty staged tree. Only OS endpoints are fixtures."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallFlow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pixel9pro_install_")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = self.root / "data/adb/modules/pixel9pro_control"
        self.new = self.root / "data/adb/modules_update/pixel9pro_control"
        self.new.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("customize.sh", "service.sh", "uecap_profile.sh", "post-mount.sh",
                     "post-fs-data.sh", "module.prop"):
            shutil.copyfile(ROOT / name, self.new / name)
        for name in ("scripts", "config", "webroot/cgi-bin", "payloads"):
            shutil.copytree(ROOT / name, self.new / name)
        for p in [*self.new.glob("*.sh"), *(self.new / "scripts").glob("*.sh")]:
            text = p.read_text().replace("/data/adb/", str(self.root / "data/adb") + "/")
            text = text.replace("/system/bin/", str(self.bin) + "/")
            text = text.replace("[ ! -c /dev/input/event0 ]", "[ ! -f \"$KEYS\" ]")
            p.write_text(text)
        for name in ("sh", "grep", "cat"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.command("getprop", 'case "$1" in ro.product.device) echo "$DEVICE";; '
                     'ro.build.fingerprint) echo fixture/build;; ro.build.version.sdk) echo 37;; esac')
        self.command("getevent", 'k=$(head -n 1 "$KEYS"); sed -i "1d" "$KEYS"; '
                     'printf "EV_SYN SYN_REPORT 0\\nEV_KEY KEY_VOLUMEUP UP\\n"; '
                     '[ -z "$k" ] || printf "EV_KEY KEY_VOLUME%s DOWN\\n" "$k"')
        # No real OS mounts, SELinux operations, Android vendor access or ADB.
        (self.new / "scripts/vendor_source.sh").write_text(
            'case "$1" in --file) cat "$STOCK";; *) echo fingerprint=fixture/build;; esac\n')
        self.command("chcon", "exit 1")

    def command(self, name, body):
        p = self.bin / name
        p.write_text("#!/bin/sh\n" + body + "\n")
        p.chmod(0o755)

    def install(self, *, device="komodo", keys=(), success=True):
        keyfile = self.root / "keys"
        keyfile.write_text("".join(k + "\n" for k in keys))
        env = dict(os.environ, MODPATH=str(self.new), TMPDIR=str(self.root / "tmp"),
                   DEVICE=device, KEYS=str(keyfile), MAGISK_VER_CODE="fixture",
                   PIXEL9PRO_NONINTERACTIVE="0" if keys else "1",
                   STOCK=str(ROOT / "tests/fixtures/thermal" / (device + ".json")),
                   PATH=str(self.bin) + ":" + os.environ["PATH"])
        proc = subprocess.run(["sh", "-c", 'ui_print() { echo "$*"; }; abort() { exit 1; }; '
                               '. "$MODPATH/customize.sh"'], env=env, capture_output=True,
                              text=True, timeout=45)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        return proc.stdout

    def pref(self, name):
        return (self.new / name).read_text().strip()

    def old_files(self, files):
        self.old.mkdir(parents=True)
        (self.old / "module.prop").write_text("id=pixel9pro_control\n")
        for key, value in files.items():
            (self.old / key).write_text(value)

    def test_clean_komodo_defaults(self):
        self.install()
        self.assertEqual((self.pref(".thermal_policy"), self.pref(".thermal_offset"),
                          self.pref(".nr_screen_switch")), ("system", "0", "off"))
        self.assertFalse((self.new / "system/vendor/etc/thermal_info_config.json").exists())
        self.assertEqual(self.pref(".uecap_policy"), "external")

    def test_clean_caiman_keys(self):
        # Move twice from system to +2, confirm CPU, explicitly enable NR.
        self.install(device="caiman", keys=["UP", "UP", "DOWN", "DOWN", "UP", "DOWN", "DOWN"])
        self.assertEqual((self.pref(".thermal_policy"), self.pref(".thermal_offset"),
                          self.pref(".nr_screen_switch")), ("custom", "2", "on"))
        self.assertTrue((self.new / "system/vendor/etc/thermal_info_config.json").is_file())
        self.assertEqual(self.pref(".uecap_policy"), "disabled")

    def test_upgrade_preserves_selected_values(self):
        old = {".state_schema": "1", ".thermal_policy": "custom", ".thermal_offset": "4",
               ".ntp_server": "time.android.com", ".nr_screen_switch": "on",
               ".sched_owner_desired": "external", ".cpu_sched_owner": "pixel"}
        self.old_files(old)
        self.install()
        for key, value in old.items():
            self.assertEqual(self.pref(key), value)
            self.assertEqual((self.old / key).read_text(), value)

    def test_legacy_without_overlay(self):
        self.old_files({})
        self.install()
        self.assertEqual((self.pref(".thermal_policy"), self.pref(".thermal_offset")), ("system", "0"))

    def test_unavailable_memory_source_does_not_abort_unrelated_install(self):
        (self.new / "scripts/vendor_source.sh").write_text("exit 1\n")
        self.assertIn("未取得设备原始内存配置", self.install())
        self.assertFalse((self.new / ".memory_original").exists())
        self.assertEqual(self.pref(".state_schema"), "1")

    def test_komodo_explicit_candidate_survives_apatch_upgrade(self):
        adb_root = self.root / "data/adb"
        (adb_root / "ap").mkdir()
        meta = adb_root / "hybrid-mount"
        meta.mkdir()
        (meta / "config.toml").touch()
        (meta / "module.prop").write_text("id=hybrid_mount\nmetamodule=1\n")
        (adb_root / "metamodule").symlink_to(meta)
        self.old_files({".state_schema": "1", ".device_variant": "komodo", ".thermal_policy": "system",
                        ".thermal_offset": "0", ".uecap_mode": "candidate", ".uecap_manual_mode": "candidate"})
        self.install()
        self.assertEqual(self.pref(".uecap_manual_mode"), "candidate")
        src, = (self.new / "payloads/uecap/komodo").glob("*.candidate.binarypb")
        staged, = (self.new / "system/vendor/firmware/uecapconfig").glob("*.binarypb")
        self.assertEqual(staged.name, src.name.replace(".candidate", ""))
        self.assertEqual(staged.read_bytes(), src.read_bytes())

    def test_default_ntp_is_not_the_first_tsv_row(self):
        catalog = self.new / "config/ntp_servers.tsv"
        rows = catalog.read_text().splitlines()
        catalog.write_text("\n".join(reversed(rows)) + "\n")
        self.install()
        self.assertEqual(self.pref(".ntp_server"), "ntp.aliyun.com")

    def test_damaged_policy_keeps_old_module(self):
        self.old_files({".state_schema": "1", ".thermal_policy": "invalid", ".thermal_offset": "2"})
        self.install(success=False)
        self.assertEqual((self.old / ".thermal_policy").read_text(), "invalid")
        self.assertFalse((self.new / ".state_schema").exists())

    def test_current_schema_missing_policy(self):
        self.old_files({".state_schema": "1"})
        self.assertIn("旧模块缺少温控策略", self.install(success=False))


if __name__ == "__main__":
    unittest.main()
