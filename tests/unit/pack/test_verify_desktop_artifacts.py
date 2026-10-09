# -*- coding: utf-8 -*-
"""Regression tests for integrity checks on downloaded desktop installers."""

from __future__ import annotations

import hashlib
from pathlib import Path
import subprocess
import sys
import zipfile

import pytest


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
VERIFIER = REPOSITORY_ROOT / "scripts" / "pack" / "verify_desktop_artifacts.py"


def _write_checksum(path: Path) -> None:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(f"{path}.sha256").write_text(
        f"{digest}  {path.name}\n",
        encoding="ascii",
    )


def _write_file(path: Path, content: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    _write_checksum(path)
    return path


def _create_valid_artifacts(root: Path) -> dict[str, Path]:
    """The installers electron-builder emits, as the CI artifacts lay them out.

    Electron-only: there is no auto-updater sidecar set any more, so each
    Actions artifact directory holds one installer plus its checksum sidecar.
    """
    windows = _write_file(
        root / "QwenPaw-Desktop-Windows-1.0.0" / "QwenPaw-1.0.0-win-x64.exe",
        b"windows installer",
    )

    macos = (
        root / "QwenPaw-Desktop-macOS-1.0.0" / "QwenPaw-1.0.0-mac-arm64.zip"
    )
    macos.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(macos, "w") as archive:
        archive.writestr("QwenPaw.app/Contents/MacOS/QwenPaw", b"app")
    _write_checksum(macos)

    linux = _write_file(
        root
        / "QwenPaw-Desktop-Linux-arm64-1.0.0"
        / "QwenPaw-1.0.0-linux-arm64.deb",
        b"linux deb",
    )

    return {
        "windows": windows,
        "macos": macos,
        "linux-arm64": linux,
    }


def _run_verifier(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--root",
            str(root),
            "--require",
            "windows",
            "--require",
            "macos",
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def test_valid_installers_pass(tmp_path: Path) -> None:
    _create_valid_artifacts(tmp_path)

    result = _run_verifier(tmp_path)

    assert result.returncode == 0, result.stderr
    assert "verified windows artifact" in result.stdout
    assert "verified macos artifact" in result.stdout
    assert "verified linux-arm64 artifact" in result.stdout


@pytest.mark.parametrize(
    "key",
    ["windows", "macos", "linux-arm64"],
)
def test_tampered_installer_fails_checksum(
    tmp_path: Path,
    key: str,
) -> None:
    """A changed installer must be rejected by its checksum sidecar.

    The sidecar itself stays intact -- that is the threat being modelled: the
    download is swapped, the published hash is not.
    """
    files = _create_valid_artifacts(tmp_path)
    files[key].write_bytes(b"tampered installer")

    result = _run_verifier(tmp_path)

    assert result.returncode == 1, result.stdout
    assert "SHA-256 mismatch" in result.stderr
