"""Run the portable async profile fixture on a real POSIX project filesystem."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


SOURCE = Path(__file__).resolve().parents[1]
work = SOURCE.parent / "work"
work.mkdir(exist_ok=True)
FILES = ["tests/profile_cgi_contract_test.sh", "webroot/cgi-bin/_common.sh", "webroot/cgi-bin/profile.sh"]
FILES += [f"scripts/{name}.sh" for name in (
    "scheduler_capability_lib", "scheduler_detect_lib", "scheduler_owner_lib", "cpu_profile_lib",
    "scheduler_boot_mode_lib", "scheduler_transition_guard_lib", "profile_state_lib",
    "scheduler_async_lib", "scheduler_async_worker", "state_io_lib", "background_tasks_lib", "display_state_lib")]

with tempfile.TemporaryDirectory(prefix="profile-request-", dir=work) as scratch:
    root = Path(scratch)
    assert root.resolve().parent == work.resolve() and root.name.startswith("profile-request-")
    mounted = False
    try:
        if os.environ.get("PROFILE_REQUEST_TEST_TMPFS") == "1":
            subprocess.run(["mount", "-t", "tmpfs", "-o", "size=8m,mode=700", "tmpfs", str(root)], check=True)
            mounted = True
            subprocess.run(["mountpoint", "-q", str(root)], check=True)
            assert subprocess.check_output(["stat", "-f", "-c", "%T", str(root)], text=True).strip() == "tmpfs"
        source = root / "source"
        for name in FILES:
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((SOURCE / name).read_text())
            subprocess.run(["sh", "-n", str(target)], check=True)
        result = subprocess.run(["sh", str(source / "tests/profile_cgi_contract_test.sh"), str(source), str(root / "fixture")],
                                text=True, capture_output=True, timeout=90)
        print(result.stdout)
        if result.stderr:
            print(result.stderr)
        assert result.returncode == 0, f"portable async fixture failed: {result.returncode}"
        blocks = dict(re.findall(r"@@(\w+)\n(.*?)\n@@END", result.stdout, re.S))
        data = {key: json.loads(value.split("\n\n", 1)[1]) for key, value in blocks.items()}
        assert set(data) == {"accepted", "pending", "busy", "success", "failed", "deferred", "screen_off",
                             "retry", "rollback", "queue_failure", "invalid", "unconfirmed"}
        assert data["accepted"]["accepted"] is True and data["accepted"]["final"] is False
        job_id = data["accepted"]["scheduler_operation"]["id"]
        assert job_id and data["pending"]["scheduler_operation"]["id"] == job_id
        assert data["success"]["scheduler_operation"]["id"] == job_id
        for name, phase, code in (("success", "success", 0), ("failed", "failed", 1),
                                  ("deferred", "deferred", 75), ("screen_off", "deferred", 75),
                                  ("retry", "success", 0)):
            operation = data[name]["scheduler_operation"]
            assert operation["phase"] == phase and operation["result_code"] == code and operation["pending"] is False
        for name in ("busy", "rollback", "queue_failure", "invalid"):
            assert data[name]["ok"] is False
        assert data["unconfirmed"]["scheduler_operation"]["phase"] == "unconfirmed"
        assert not (root / "fixture/mod/.scheduler_async.lock").exists()
        assert not (root / "fixture/mod/.locks/profile.lock").exists()
        assert not (root / "fixture/fas/.owner_transition.lock").exists()
        print("PASS structured async observations, exact job identity and final lock cleanup")
    finally:
        if mounted:
            subprocess.run(["umount", str(root)], check=True)
            assert subprocess.run(["mountpoint", "-q", str(root)]).returncode != 0
            assert list(root.iterdir()) == [], "project mount point has underlying survivors"
