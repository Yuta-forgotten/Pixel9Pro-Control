#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# This module is loaded by release_contract.py while auditing a release ZIP.
# Invoke audit_release.py rather than running this file directly.
# ──────────────────

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Final

from release_contract import ContractError, validate_runtime_text


EXPECTED_MODES: Final = {"caiman": {"balanced", "special", "universal"}, "komodo": {"candidate"}}
EXPECTED_TARGETS: Final = {
    "caiman": "PLATFORM_9055801516233416490.binarypb",
    "komodo": "PLATFORM_6287228797510365516.binarypb",
}


@dataclass(frozen=True, slots=True)
class PayloadSpec:
    device: str
    mode: str
    source: str
    target: str
    size: int
    sha256: str
    state: str
    source_build: str


def _error(detail: str) -> ContractError:
    return ContractError(detail=detail)


def _parse_manifest(data: bytes) -> tuple[PayloadSpec, ...]:
    text = validate_runtime_text("config/uecap_payloads.tsv", data)
    specs: list[PayloadSpec] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = raw_line.split("|")
        if len(fields) != 8:
            raise _error(f"invalid UECap payload row {line_number}: expected 8 fields")
        device, mode, source, target, raw_size, digest, state, source_build = fields
        try:
            size = int(raw_size)
        except ValueError as exc:
            raise _error(f"invalid UECap payload size on row {line_number}") from exc
        specs.append(PayloadSpec(device, mode, source, target, size, digest, state, source_build))
    return tuple(specs)


def audit_payloads(entries: dict[str, bytes]) -> tuple[str, ...]:
    manifest = entries.get("config/uecap_payloads.tsv")
    packaged = {path for path in entries if path.endswith(".binarypb") and path.startswith("payloads/uecap/")}
    if manifest is None:
        if packaged:
            raise _error("UECap staging payloads require config/uecap_payloads.tsv")
        return ()
    specs = _parse_manifest(manifest)
    actual_modes: dict[str, set[str]] = {device: set() for device in EXPECTED_MODES}
    for spec in specs:
        if spec.device not in actual_modes or spec.target != EXPECTED_TARGETS[spec.device]:
            raise _error(f"invalid UECap device/target contract: {spec.device}/{spec.target}")
        if not spec.source.startswith(f"payloads/uecap/{spec.device}/"):
            raise _error(f"cross-SKU UECap source path: {spec.source}")
        payload = entries.get(spec.source)
        if payload is None:
            raise _error(f"declared UECap payload is missing: {spec.source}")
        if len(payload) != spec.size or hashlib.sha256(payload).hexdigest() != spec.sha256:
            raise _error(f"UECap bytes/hash mismatch: {spec.source}")
        if spec.state not in {"candidate", "verified"} or not spec.source_build:
            raise _error(f"invalid UECap provenance: {spec.source}")
        actual_modes[spec.device].add(spec.mode)
    if actual_modes != EXPECTED_MODES:
        raise _error(f"incomplete UECap mode contract: {actual_modes}")
    declared = {spec.source for spec in specs}
    if packaged != declared:
        raise _error("undeclared or missing UECap staging payload")
    return tuple(sorted(actual_modes))
