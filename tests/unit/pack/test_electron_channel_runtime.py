# -*- coding: utf-8 -*-
"""Verify the Electron desktop package ships a readable channel runtime.

``qwenpaw.plugins.channel_bootstrap`` refuses a partially populated launcher
environment: ``QWENPAW_TAURI_RESOURCE_DIR`` and the three ``QWENPAW_CHANNEL_*``
variables must be set together or not at all, otherwise desktop channel plugins
fail with ``CHANNEL_RUNTIME_MANIFEST_INVALID``. The Tauri build stages the
manifest inside ``build_pyinstaller.*`` (under ``console/src-tauri``), which the
Electron build skips, so the shell has to do it itself.
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
BUILD_SCRIPTS = (
    REPO_ROOT / "scripts" / "pack-electron" / "build_win.sh",
    REPO_ROOT / "scripts" / "pack-electron" / "build_macos.sh",
    REPO_ROOT / "scripts" / "pack-electron" / "build_linux.sh",
)
MAIN_JS = REPO_ROOT / "console" / "electron" / "main.js"
LAUNCHER_KEYS = (
    "QWENPAW_TAURI_RESOURCE_DIR",
    "QWENPAW_CHANNEL_RUNTIME_MANIFEST",
    "QWENPAW_CHANNEL_SUPPORT_ROOT",
    "QWENPAW_CHANNEL_DEPENDENCY_PATHS",
    "QWENPAW_DESKTOP_PY_RUNTIME",
)


@pytest.mark.parametrize("script", BUILD_SCRIPTS, ids=lambda item: item.name)
def test_electron_builds_stage_the_channel_runtime(script: Path) -> None:
    """Every Electron build must stage the manifest Tauri staging skipped."""
    contents = script.read_text(encoding="utf-8")

    assert "stage_channel_runtime.sh" in contents
    assert (
        '"${REPO_ROOT}/console/electron"' in contents
    ), f"{script.name}: resource-dir must be the Electron resource root"


@pytest.mark.parametrize("script", BUILD_SCRIPTS, ids=lambda item: item.name)
def test_backend_extras_include_channels(script: Path) -> None:
    """The offline wheel pool must contain the channel dependency wheels."""
    contents = script.read_text(encoding="utf-8")

    extras_lines = [
        line for line in contents.splitlines() if "QWENPAW_EXTRAS=" in line
    ]

    assert extras_lines, f"{script.name}: no QWENPAW_EXTRAS default found"
    for line in extras_lines:
        assert "channels" in line, f"{script.name}: {line.strip()}"


def test_main_exports_the_full_launcher_environment() -> None:
    """The shell guards all five variables behind a single channel-ready check.

    ``qwenpaw.plugins.channel_bootstrap`` rejects a partially populated launcher
    environment with ``CHANNEL_RUNTIME_MANIFEST_INVALID``: ``QWENPAW_TAURI_RESOURCE_DIR``
    must be exported *together with* the three ``QWENPAW_CHANNEL_*`` variables, never
    unconditionally on its own. If the readable channel runtime was not staged the
    shell must export none of them, letting the frozen backend fall back to its
    default layout (it still finds the manifest via the backend binary's own path).
    """
    contents = MAIN_JS.read_text(encoding="utf-8")

    for key in LAUNCHER_KEYS:
        assert f"env.{key}" in contents, f"missing launcher variable: {key}"

    guard_index = contents.find("const channelReady =")
    assert guard_index != -1, "expected a channelReady guard in main.js"
    resource_assignment = contents.find("env.QWENPAW_TAURI_RESOURCE_DIR")
    assert resource_assignment != -1
    assert resource_assignment > guard_index, (
        "QWENPAW_TAURI_RESOURCE_DIR must be set inside the channelReady block, "
        "not unconditionally; otherwise a missing manifest yields a partially "
        "populated launcher environment and CHANNEL_RUNTIME_MANIFEST_INVALID."
    )


def test_main_python_runtime_matches_the_staged_layout() -> None:
    """The manifest pins the interpreter, so both sides must agree."""
    contents = MAIN_JS.read_text(encoding="utf-8")
    staged = (
        REPO_ROOT / "scripts" / "pack-tauri" / "stage_python_runtime.py"
    ).read_text(encoding="utf-8")

    assert 'path.join(BINARIES, "python-runtime", "python")' in contents
    assert 'dest / "python" / "bin" / "python3"' in staged
    assert 'dest / "python" / "python.exe"' in staged
