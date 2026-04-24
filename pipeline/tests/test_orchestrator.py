"""Smoke tests for the orchestrator.

The full pipeline requires COLMAP and a GPU, so here we only verify the
structure: stage callbacks fire in order, extract_frames copies photos,
and orchestrator raises clearly when inputs are insufficient.
"""

from pathlib import Path

import pytest

from cameraworld_pipeline import orchestrator
from cameraworld_pipeline.stages import extract_frames


def test_extract_frames_copies_photos(tmp_path: Path, sharp_image) -> None:
    input_dir = tmp_path / "in"
    input_dir.mkdir()
    sharp_image("a.jpg")  # created in tmp_path, need to move
    (tmp_path / "a.jpg").rename(input_dir / "a.jpg")

    out = tmp_path / "out"
    paths = extract_frames.run(input_dir, out, fps=1.0)
    assert len(paths) == 1
    assert paths[0].exists()
    assert paths[0].name.startswith("photo_")


def test_pipeline_fails_fast_on_few_images(tmp_path: Path, sharp_image) -> None:
    input_dir = tmp_path / "in"
    input_dir.mkdir()
    sharp_image("only.jpg")
    (tmp_path / "only.jpg").rename(input_dir / "only.jpg")

    with pytest.raises(RuntimeError, match="not enough"):
        orchestrator.run_pipeline(input_dir, tmp_path / "work", enable_gs=False)


def test_stage_callback_invoked(tmp_path: Path, sharp_image, monkeypatch) -> None:
    # Monkeypatch all heavy stages to no-ops and verify stage names flow through.
    called: list[str] = []

    def fake_sfm(*a, **kw):
        (a[1] / "sparse" / "0").mkdir(parents=True, exist_ok=True)
        return a[1] / "sparse" / "0"

    def fake_mvs(*a, **kw):
        ply = a[2] / "dense" / "fused.ply"
        ply.parent.mkdir(parents=True, exist_ok=True)
        ply.write_text("ply\n")
        return ply

    def fake_tiles(*a, **kw):
        tileset = a[1] / "tileset.json"
        a[1].mkdir(parents=True, exist_ok=True)
        tileset.write_text("{}")
        return tileset

    from cameraworld_pipeline.stages import colmap_mvs, colmap_sfm, to_3dtiles

    monkeypatch.setattr(colmap_sfm, "run", fake_sfm)
    monkeypatch.setattr(colmap_mvs, "run", fake_mvs)
    monkeypatch.setattr(to_3dtiles, "run", fake_tiles)

    input_dir = tmp_path / "in"
    input_dir.mkdir()
    for i in range(6):
        img = sharp_image(f"x{i}.jpg")
        img.rename(input_dir / f"x{i}.jpg")

    artifacts = orchestrator.run_pipeline(
        input_dir,
        tmp_path / "work",
        enable_gs=False,
        on_stage=called.append,
    )

    assert artifacts.tileset_json.exists()
    assert called[0] == orchestrator.STAGE_EXTRACT
    assert orchestrator.STAGE_SFM in called
    assert orchestrator.STAGE_TILES == called[-1]
