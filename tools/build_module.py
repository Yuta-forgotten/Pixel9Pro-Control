#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# Build:    python tools/build_module.py --source . --output dist/module.zip
# Validate: python tools/build_module.py --source . --validate-only
# Hash:     python tools/build_module.py --source . --fingerprint
# ──────────────────

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import zipfile
from dataclasses import asdict
from pathlib import Path

from release_contract import ContractError, audit_zip, collect_runtime_files, source_fingerprint, write_deterministic_zip


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a deterministic Pixel9Pro-Control module ZIP")
    parser.add_argument("--source", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--fingerprint", action="store_true")
    return parser.parse_args()


def run() -> int:
    args = parse_args()
    source = args.source.resolve()
    files = collect_runtime_files(source)
    fingerprint = source_fingerprint(files)
    if args.fingerprint:
        print(fingerprint)
        return 0
    if args.validate_only:
        print(json.dumps({"ok": True, "files": len(files), "source_fingerprint": fingerprint}, ensure_ascii=False))
        return 0
    if args.output is None:
        raise ContractError(detail="--output is required unless --validate-only or --fingerprint is used")
    output = args.output.resolve()
    if output.suffix.lower() != ".zip" or any(output == item.source_path.resolve() for item in files):
        raise ContractError(detail="--output must be a ZIP path outside the runtime source files")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=f".{output.name}.", suffix=".candidate", dir=output.parent, delete=False) as handle:
        candidate = Path(handle.name)
    try:
        write_deterministic_zip(files, candidate)
        report = audit_zip(candidate)
        candidate.replace(output)
    finally:
        candidate.unlink(missing_ok=True)
    result = asdict(report)
    result["archive"] = str(output)
    result["source_fingerprint"] = fingerprint
    result["ok"] = True
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
