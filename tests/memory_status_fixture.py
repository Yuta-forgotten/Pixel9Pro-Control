"""Replay the production read-only AWK snapshot against explicit kernel inputs."""
import json
from pathlib import Path
import re
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]
policy = re.search(r'-v policy="([^"]+)"', (SOURCE / "webroot/cgi-bin/swap.sh").read_text()).group(1)
policy = subprocess.check_output(["sh", "-c", '. "$1/scripts/memory_lib.sh"; printf "%s" "' + policy + '"',
                                  "fixture", str(SOURCE)], text=True)
cases = []
with tempfile.TemporaryDirectory(prefix="memory-status-", dir=SOURCE.parent / "work") as temporary:
    root = Path(temporary)
    (root / ".vm_policy_ready").write_text("true")
    nodes = {
        "proc/sys/kernel/random/boot_id": "fixture-boot\n",
        "proc/sys/vm/swappiness": "60\n", "proc/sys/vm/min_free_kbytes": "27386\n",
        "proc/sys/vm/watermark_scale_factor": "200\n", "proc/sys/vm/vfs_cache_pressure": "100\n",
        "proc/pressure/memory": "some avg10=0.00\nfull avg10=0.00\n",
        "sys/block/zram0/disksize": "104857600\n", "sys/block/zram0/comp_algorithm": "[lz4] lzo-rle\n",
        "sys/block/zram0/mm_stat": "2048 1024 4096\n", "sys/block/zram0/bd_stat": "0 0 0\n",
        "sys/block/zram0/io_stat": "0 0 0\n",
    }
    for name, value in nodes.items():
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)
    # Only substitute external filesystem roots. No algorithm or branch changes.
    awk = root / "memory_status.awk"
    awk.write_text((SOURCE / "scripts/memory_status.awk").read_text()
                   .replace('"/proc/', f'"{root}/proc/').replace('"/sys/', f'"{root}/sys/'))
    for state, mmd, swap_total in [("active", "true", 102400), ("inactive", "true", 0),
                                   ("unknown", "true", 102400), ("active", "false", 102400)]:
        (root / "proc/meminfo").write_text(f"MemTotal: 8388608 kB\nMemAvailable: 6291456 kB\nSwapTotal: {swap_total} kB\n")
        (root / "proc/swaps").write_text("Filename Type Size Used Priority\n" +
            ("/dev/block/zram0 partition 102400 100 -2\n" if state == "active" else ""))
        props = {"ro.build.fingerprint": "fixture-build", "ro.build.version.sdk": "37",
                 "mmd.zram.enabled": mmd, "mmd.setup_complete": "true", "init.svc.mmd": "running"}
        result = subprocess.run(["awk", "-v", f"root={root}", "-v", "pagesize=4096", "-v", "setup=true",
                                 "-v", f"policy={policy}", "-f", str(awk)],
                                input="".join(f"[{k}]: [{v}]\n" for k, v in props.items()),
                                text=True, capture_output=True, check=True)
        payload = json.loads(result.stdout)
        assert payload["zram_active_state"] == state
        assert payload["zram_active"] is (state == "active")
        assert payload["zram_owner"] == ("mmd" if mmd == "true" else "unknown")
        assert payload["zram_online_supported"] is (state == "active" and mmd == "true")
        assert payload["zram_algo"] == "lz4" and payload["zram_disksize"] == 104857600
        cases.append(payload)
print(json.dumps(cases))
