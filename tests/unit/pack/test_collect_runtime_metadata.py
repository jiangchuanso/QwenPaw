# -*- coding: utf-8 -*-
"""Regression tests for the PyInstaller runtime metadata collector."""

from __future__ import annotations

import runpy
from importlib import metadata
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
MODULE = REPO_ROOT / "scripts" / "pack-tauri" / "collect_runtime_metadata.py"
namespace = runpy.run_path(str(MODULE))
collect_runtime_metadata = namespace["collect_runtime_metadata"]


def test_missing_optional_distribution_is_skipped(monkeypatch, capsys):
    def fake_distribution(name):
        if name == "qwenpaw":
            return SimpleNamespace(
                version="2.3.0",
                requires=["openai-whisper>=20231117"],
            )
        raise metadata.PackageNotFoundError(name)

    copied = []

    def fake_copy_metadata(name):
        copied.append(name)
        return [(f"{name}.dist-info", ".")]

    monkeypatch.setattr(metadata, "distribution", fake_distribution)

    datas = collect_runtime_metadata(["qwenpaw[full]"], fake_copy_metadata)

    assert copied == ["qwenpaw"]
    assert datas == [("qwenpaw.dist-info", ".")]
    assert "openai-whisper" in capsys.readouterr().out


def test_version_mismatch_still_fails(monkeypatch):
    monkeypatch.setattr(
        metadata,
        "distribution",
        lambda name: SimpleNamespace(version="1.0.0", requires=[]),
    )

    with pytest.raises(ValueError, match="Incompatible desktop dependency"):
        collect_runtime_metadata(["qwenpaw==2.0.0"], lambda name: [])
