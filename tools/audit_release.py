#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# Audit:   python tools/audit_release.py path/to/module.zip
# Compare: python tools/audit_release.py first.zip --compare second.zip
# ──────────────────

from __future__ import annotations

import argparse
import json
import sys
import zipfile
from dataclasses import asdict
from pathlib import Path

from release_contract import ContractError, audit_zip


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit a Pixel9Pro-Control release ZIP")
    parser.add_argument("archive", type=Path)
    parser.add_argument("--compare", type=Path)
    return parser.parse_args()


def run() -> int:
    args = parse_args()
    primary = audit_zip(args.archive.resolve())
    result = asdict(primary)
    result["ok"] = True
    if args.compare is not None:
        comparison = audit_zip(args.compare.resolve())
        if primary.sha256 != comparison.sha256:
            raise ContractError(
                detail=f"deterministic build mismatch: {primary.sha256} != {comparison.sha256}"
            )
        result["compare_archive"] = comparison.archive
        result["deterministic_match"] = True
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


def main() -> int:
    try:
        return run()
    except (ContractError, OSError, zipfile.BadZipFile) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
