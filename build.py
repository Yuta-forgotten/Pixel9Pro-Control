"""
build.py — Pixel9Pro-Control module builder
============================================
Generates the installable APatch/KernelSU ZIP for Pixel 9 Pro thermal + CPU control.

Usage:
    python build.py [output_zip]

    Default output: Pixel9Pro_Control.zip (in the same directory as this script)

Requirements:
    - Python 3.8+
    - etc/thermal_info_config.json  (stock thermal config pulled from device)
      Pull command: adb pull /vendor/etc/thermal_info_config.json etc/

Device:   Pixel 9 Pro (caiman / Tensor G4)
Module:   pixel9pro_control  (APatch/KernelSU native format, no META-INF)
Port:     6210 (busybox httpd WebUI)
"""
import copy
import json
import os
import sys
import zipfile

# ---------------------------------------------------------------------------
# Paths (all relative to this script's location)
# ---------------------------------------------------------------------------
SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
STOCK_JSON  = os.path.join(SCRIPT_DIR, "etc", "thermal_info_config.json")
THERMAL_OUT = os.path.join(SCRIPT_DIR, "system", "vendor", "etc", "thermal_info_config.json")
STOCK_OUT   = os.path.join(SCRIPT_DIR, "system", "vendor", "etc", "thermal_stock.json")
OUT_ZIP     = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SCRIPT_DIR, "Pixel9Pro_Control.zip")

# ---------------------------------------------------------------------------
# Thermal modifications
#
# Strategy: uniform +4°C offset on performance-path sensors only.
# Charging sensors (CHARGE-WIRED / CHARGE-PERSIST) are intentionally left
# untouched — modifying CHARGE-PERSIST causes thermal service to reject start.
#
# Strict monotonic increase is enforced; build aborts if violated.
#
# Stock → +4°C:
#   VIRTUAL-SKIN:      [NAN, 39, 43, 45, 46.5, 52, 55] → [NAN, 43, 47, 49, 50.5, 56, 59]
#   VIRTUAL-SKIN-HINT: [NAN, 37, 43, 45, 46.5, 52, 55] → [NAN, 41, 47, 49, 50.5, 56, 59]
#   VIRTUAL-SKIN-SOC:  [NAN, 37, 43, 45, 46.5, 52, 55] → [NAN, 41, 47, 49, 50.5, 56, 59]
# ---------------------------------------------------------------------------
THERMAL_MODS = {
    "VIRTUAL-SKIN": {
        "HotThreshold": ["NAN", 43.0, 47.0, 49.0, 50.5, 56.0, 59.0],
    },
    "VIRTUAL-SKIN-HINT": {
        "HotThreshold": ["NAN", 41.0, 47.0, 49.0, 50.5, 56.0, 59.0],
    },
    "VIRTUAL-SKIN-SOC": {
        "HotThreshold": ["NAN", 41.0, 47.0, 49.0, 50.5, 56.0, 59.0],
    },
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def ensure_monotonic(name, seq):
    nums = [v for v in seq if isinstance(v, (int, float))]
    if nums != sorted(nums):
        raise ValueError(f"{name}: HotThreshold is not strictly increasing: {seq}")


def apply_thermal_mods(config, mods):
    modified, seen = [], set()
    for sensor in config.get("Sensors", []):
        name = sensor.get("Name", "")
        if name not in mods:
            continue
        before = list(sensor.get("HotThreshold", []))
        after  = mods[name]["HotThreshold"]
        ensure_monotonic(name, after)
        sensor["HotThreshold"] = after
        modified.append((name, before, after))
        seen.add(name)
    missing = sorted(set(mods.keys()) - seen)
    if missing:
        raise KeyError(f"Sensors not found in stock JSON: {missing}")
    return modified


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
        f.write("\n")


def build_zip(src_dir, out_zip):
    if os.path.exists(out_zip):
        os.remove(out_zip)

    # Files/dirs to exclude from ZIP (build tooling, not module content)
    SKIP_DIRS  = {"etc", "__pycache__", ".git"}
    SKIP_FILES = {"build.py", "Pixel9Pro_Control.zip"}

    entries = []
    for root, dirs, files in os.walk(src_dir):
        dirs[:] = [d for d in dirs
                   if not d.startswith('.') and d not in SKIP_DIRS]
        for fname in files:
            if fname.startswith('.') and fname != '.current_profile':
                continue
            if fname in SKIP_FILES or fname.endswith('.zip'):
                continue
            abs_path = os.path.join(root, fname)
            rel_path = os.path.relpath(abs_path, src_dir).replace('\\', '/')
            entries.append((abs_path, rel_path))

    entries.sort(key=lambda x: x[1])

    with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for abs_path, arc_name in entries:
            info = zipfile.ZipInfo(arc_name)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if arc_name.endswith('.sh') else 0o100644) << 16
            with open(abs_path, 'rb') as f:
                zf.writestr(info, f.read())
            _print(f"  + {arc_name}")

    with zipfile.ZipFile(out_zip, 'r') as zf:
        bad = [n for n in zf.namelist() if '\\' in n]
    if bad:
        raise RuntimeError(f"[ERROR] {len(bad)} entries still have backslash!")
    _print("  [OK] All paths use forward slashes")


def _print(msg):
    sys.stdout.buffer.write((msg + "\n").encode("utf-8"))


def main():
    _print("=== Pixel9Pro-Control build.py ===\n")

    # Step 1: Generate thermal JSONs
    _print("[1/3] Generating thermal JSONs...")
    if not os.path.exists(STOCK_JSON):
        _print(f"  [ERROR] Stock thermal JSON not found: {STOCK_JSON}")
        _print("  Pull it from device: adb pull /vendor/etc/thermal_info_config.json etc/")
        sys.exit(1)

    with open(STOCK_JSON, "r", encoding="utf-8") as f:
        config = json.load(f)

    stock_copy = copy.deepcopy(config)
    write_json(STOCK_OUT, stock_copy)
    _print(f"  Stock copy  : {STOCK_OUT}")

    modified = apply_thermal_mods(config, THERMAL_MODS)
    write_json(THERMAL_OUT, config)
    _print(f"  Active (+4°C): {THERMAL_OUT}")
    _print("  Changes:")
    for name, before, after in modified:
        _print(f"    {name}")
        _print(f"      Before: {before}")
        _print(f"      After : {after}")

    # Step 2: Package ZIP
    _print("\n[2/3] Packaging ZIP...")
    build_zip(SCRIPT_DIR, OUT_ZIP)

    # Step 3: Summary
    size = os.path.getsize(OUT_ZIP)
    with zipfile.ZipFile(OUT_ZIP, 'r') as zf:
        file_count = len(zf.namelist())
    _print(f"\n[3/3] Done.")
    _print(f"  Output : {OUT_ZIP}")
    _print(f"  Size   : {size:,} bytes")
    _print(f"  Files  : {file_count}")
    _print("\nInstall:")
    _print("  adb push Pixel9Pro_Control.zip /sdcard/Download/")
    _print("  APatch / KernelSU → Modules → + → select file → Install → Reboot")


if __name__ == "__main__":
    main()
