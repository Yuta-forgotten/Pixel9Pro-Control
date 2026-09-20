#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# ─── How to run ───
# This is the shared release-contract module. Invoke build_module.py or
# audit_release.py with Python 3.11+; no third-party package is required.
# ──────────────────

from __future__ import annotations

import hashlib
import json
import re
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Final


ROOT_FILES: Final = frozenset(
    {
        "customize.sh",
        "module.prop",
        "post-mount.sh",
        "service.sh",
        "uecap_profile.sh",
        "versions.prop",
    }
)
ROOT_DIRS: Final = frozenset({"META-INF", "config", "payloads", "scripts", "system", "webroot"})
TEXT_SUFFIXES: Final = frozenset({".css", ".html", ".js", ".json", ".prop", ".sh", ".tsv", ".xml"})
REQUIRED_ENTRIES: Final = frozenset(
    {
        "META-INF/com/google/android/update-binary",
        "META-INF/com/google/android/updater-script",
        "customize.sh",
        "module.prop",
        "post-mount.sh",
        "service.sh",
        "versions.prop",
        "webroot/index.html",
    }
)
EXCLUDED_PARTS: Final = frozenset(
    {".git", "docs", "logs", "modules", "node_modules", "scratch", "tests", "tmp", "tools"}
)
FIXED_ZIP_TIME: Final = (1980, 1, 1, 0, 0, 0)
MAX_FILE_BYTES: Final = 32 * 1024 * 1024
MAX_ARCHIVE_BYTES: Final = 256 * 1024 * 1024
MAX_ENTRIES: Final = 10_000
CANONICAL_TARGET: Final = re.compile(
    r"^system/vendor/firmware/uecapconfig/PLATFORM_[0-9]+\.binarypb$"
)
PRIVATE_DATA: Final = (
    re.compile(r"C:\\Users\\[^\\\s]+", re.IGNORECASE),
    re.compile(r"/Users/[^/\s]+"),
    re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b"),
    re.compile(r"\b[0-9]{15,16}\b"),
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.IGNORECASE),
)


@dataclass(frozen=True, slots=True)
class ContractError(Exception):
    detail: str

    def __str__(self) -> str:
        return self.detail


@dataclass(frozen=True, slots=True)
class RuntimeFile:
    archive_path: str
    source_path: Path
    data: bytes
    mode: int


@dataclass(frozen=True, slots=True)
class AuditReport:
    archive: str
    sha256: str
    entries: int
    uncompressed_bytes: int
    module_version: str
    webui_version: str
    payload_devices: tuple[str, ...]


def _error(detail: str) -> ContractError:
    return ContractError(detail=detail)


def _is_text(path: str) -> bool:
    return PurePosixPath(path).suffix.lower() in TEXT_SUFFIXES or path.startswith("META-INF/")


def _mode_for(path: str) -> int:
    return 0o755 if path.endswith(".sh") or path.endswith("/update-binary") else 0o644


def _validate_archive_path(path: str) -> None:
    pure = PurePosixPath(path)
    if not path or "\\" in path or pure.is_absolute() or ".." in pure.parts:
        raise _error(f"unsafe archive path: {path!r}")
    if pure.parts[0] not in ROOT_DIRS and path not in ROOT_FILES:
        raise _error(f"path is outside the runtime allowlist: {path}")
    if any(part in EXCLUDED_PARTS for part in pure.parts):
        raise _error(f"excluded path entered the runtime package: {path}")
    if CANONICAL_TARGET.fullmatch(path):
        raise _error(f"canonical UECap target must not be pre-activated in ZIP: {path}")


def validate_runtime_text(path: str, data: bytes) -> str:
    if data.startswith(b"\xef\xbb\xbf"):
        raise _error(f"UTF-8 BOM is forbidden: {path}")
    if b"\r" in data:
        raise _error(f"CR/CRLF is forbidden: {path}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise _error(f"runtime text is not UTF-8: {path}: {exc}") from exc
    for pattern in PRIVATE_DATA:
        if match := pattern.search(text):
            raise _error(f"possible personal data in {path}: {match.group(0)!r}")
    if path.endswith(".json"):
        try:
            json.loads(text)
        except json.JSONDecodeError as exc:
            raise _error(f"invalid JSON in {path}: {exc}") from exc
    return text


def _read_properties(data: bytes, path: str) -> dict[str, str]:
    text = validate_runtime_text(path, data)
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or key in values:
            raise _error(f"invalid or duplicate property in {path}: {raw_line!r}")
        values[key] = value
    return values


def _transform(root: Path, archive_path: str, data: bytes) -> bytes:
    if archive_path != "webroot/index.html":
        return data
    versions_path = root / "versions.prop"
    versions = _read_properties(versions_path.read_bytes(), "versions.prop")
    stamp = versions.get("webui", "")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", stamp):
        raise _error("versions.prop has an invalid webui version")
    text = validate_runtime_text(archive_path, data)
    if "__WEBUI_VER__" not in text:
        raise _error("webroot/index.html is missing __WEBUI_VER__")
    return text.replace("__WEBUI_VER__", stamp).encode()


def collect_runtime_files(root: Path) -> tuple[RuntimeFile, ...]:
    if not root.is_dir():
        raise _error(f"source directory does not exist: {root}")
    candidates = [root / name for name in ROOT_FILES]
    for directory in sorted(ROOT_DIRS):
        base = root / directory
        if base.exists():
            candidates.extend(path for path in base.rglob("*") if path.is_file() or path.is_symlink())
    files: list[RuntimeFile] = []
    seen: set[str] = set()
    for source in sorted(candidates, key=lambda item: item.as_posix()):
        if source.is_symlink():
            raise _error(f"symbolic links are forbidden in release input: {source}")
        if not source.is_file():
            raise _error(f"required runtime file is missing: {source}")
        archive_path = source.relative_to(root).as_posix()
        _validate_archive_path(archive_path)
        if archive_path in seen:
            raise _error(f"duplicate runtime path: {archive_path}")
        seen.add(archive_path)
        data = _transform(root, archive_path, source.read_bytes())
        if len(data) > MAX_FILE_BYTES:
            raise _error(f"runtime file exceeds {MAX_FILE_BYTES} bytes: {archive_path}")
        if _is_text(archive_path):
            validate_runtime_text(archive_path, data)
        elif archive_path.endswith(".binarypb") and not data:
            raise _error(f"empty UECap payload: {archive_path}")
        files.append(RuntimeFile(archive_path, source, data, _mode_for(archive_path)))
    missing = REQUIRED_ENTRIES.difference(seen)
    if missing:
        raise _error(f"required runtime entries are missing: {', '.join(sorted(missing))}")
    total = sum(len(item.data) for item in files)
    if len(files) > MAX_ENTRIES or total > MAX_ARCHIVE_BYTES:
        raise _error(f"runtime package exceeds safety bounds: files={len(files)} bytes={total}")
    return tuple(files)


def source_fingerprint(files: tuple[RuntimeFile, ...]) -> str:
    digest = hashlib.sha256()
    for item in files:
        digest.update(item.archive_path.encode())
        digest.update(b"\0")
        digest.update(str(item.mode).encode())
        digest.update(b"\0")
        digest.update(item.data)
        digest.update(b"\0")
    return digest.hexdigest()


def write_deterministic_zip(files: tuple[RuntimeFile, ...], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(f".{output.name}.tmp")
    temporary.unlink(missing_ok=True)
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for item in files:
            info = zipfile.ZipInfo(item.archive_path, FIXED_ZIP_TIME)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (stat.S_IFREG | item.mode) << 16
            archive.writestr(info, item.data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    temporary.replace(output)


def audit_zip(path: Path) -> AuditReport:
    if not path.is_file():
        raise _error(f"ZIP does not exist: {path}")
    archive_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)) or names != sorted(names):
            raise _error("ZIP entries are duplicated or not deterministically sorted")
        if len(names) > MAX_ENTRIES:
            raise _error(f"ZIP entry count exceeds {MAX_ENTRIES}")
        entries: dict[str, bytes] = {}
        total = 0
        for info in infos:
            _validate_archive_path(info.filename)
            if info.is_dir() or stat.S_ISLNK(info.external_attr >> 16):
                raise _error(f"directories and symlinks are forbidden: {info.filename}")
            if info.date_time != FIXED_ZIP_TIME:
                raise _error(f"non-deterministic ZIP timestamp: {info.filename}")
            mode = (info.external_attr >> 16) & 0o777
            if mode != _mode_for(info.filename):
                raise _error(f"wrong ZIP permission {mode:o}: {info.filename}")
            if info.file_size > MAX_FILE_BYTES:
                raise _error(f"oversized ZIP entry: {info.filename}")
            data = archive.read(info)
            total += len(data)
            if _is_text(info.filename):
                validate_runtime_text(info.filename, data)
            entries[info.filename] = data
        if total > MAX_ARCHIVE_BYTES:
            raise _error(f"ZIP exceeds {MAX_ARCHIVE_BYTES} uncompressed bytes")
    missing = REQUIRED_ENTRIES.difference(entries)
    if missing:
        raise _error(f"ZIP required entries are missing: {', '.join(sorted(missing))}")
    index = validate_runtime_text("webroot/index.html", entries["webroot/index.html"])
    if "__WEBUI_VER__" in index:
        raise _error("WebUI cache stamp was not replaced")
    module = _read_properties(entries["module.prop"], "module.prop")
    versions = _read_properties(entries["versions.prop"], "versions.prop")
    from uecap_manifest import audit_payloads

    payload_devices = audit_payloads(entries)
    return AuditReport(
        archive=str(path),
        sha256=archive_hash,
        entries=len(entries),
        uncompressed_bytes=total,
        module_version=module.get("version", "unknown"),
        webui_version=versions.get("webui", "unknown"),
        payload_devices=payload_devices,
    )
