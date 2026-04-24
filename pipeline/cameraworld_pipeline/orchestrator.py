"""End-to-end reconstruction orchestrator.

Executes the pipeline stages sequentially and returns artifact paths.

Can be invoked directly for local smoke testing:

    python -m cameraworld_pipeline.orchestrator --input tests/fixtures/sample_capture --output /tmp/smoke
"""

from __future__ import annotations

import argparse
import logging
import shutil
from dataclasses import dataclass
from pathlib import Path

from cameraworld_pipeline.config import get_settings
from cameraworld_pipeline.stages import (
    colmap_mvs,
    colmap_sfm,
    extract_frames,
    filter_quality,
    gaussian_splat,
    to_3dtiles,
)

log = logging.getLogger(__name__)

STAGE_EXTRACT = "extract_frames"
STAGE_FILTER = "filter_quality"
STAGE_SFM = "colmap_sfm"
STAGE_MVS = "colmap_mvs"
STAGE_GS = "gaussian_splat"
STAGE_TILES = "to_3dtiles"


@dataclass
class Artifacts:
    pointcloud_ply: Path
    tileset_json: Path
    splat_ply: Path | None
    image_count: int


def run_pipeline(
    input_dir: Path,
    workdir: Path,
    enable_gs: bool = True,
    matcher: str = "sequential",
    on_stage: callable | None = None,
) -> Artifacts:
    """Execute the full pipeline.

    Args:
        input_dir: Raw inputs (photos and/or videos, flat layout).
        workdir: Scratch directory; will be populated with intermediate artifacts.
        enable_gs: If False, skip Gaussian Splatting training.
        matcher: COLMAP matcher: "sequential" for continuous video, "exhaustive" for photos.
        on_stage: Optional callback invoked as ``on_stage(stage_name)`` before each stage
            (used by the worker to persist progress).
    """
    workdir.mkdir(parents=True, exist_ok=True)
    images_dir = workdir / "images"
    if images_dir.exists():
        shutil.rmtree(images_dir)

    def _emit(stage: str) -> None:
        log.info("=== stage: %s ===", stage)
        if on_stage:
            on_stage(stage)

    _emit(STAGE_EXTRACT)
    extract_frames.run(input_dir, images_dir)

    _emit(STAGE_FILTER)
    kept = filter_quality.run(images_dir)
    if len(kept) < 5:
        raise RuntimeError(f"not enough usable frames after filtering: {len(kept)}")

    _emit(STAGE_SFM)
    sparse_dir = colmap_sfm.run(images_dir, workdir, matcher=matcher)

    _emit(STAGE_MVS)
    pointcloud = colmap_mvs.run(images_dir, sparse_dir, workdir)

    splat_ply: Path | None = None
    if enable_gs:
        _emit(STAGE_GS)
        gs_output = workdir / "gaussian"
        splat_ply = gaussian_splat.run(workdir, gs_output)

    _emit(STAGE_TILES)
    tiles_dir = workdir / "tiles"
    tileset = to_3dtiles.run(pointcloud, tiles_dir)

    return Artifacts(
        pointcloud_ply=pointcloud,
        tileset_json=tileset,
        splat_ply=splat_ply,
        image_count=len(kept),
    )


def _cli() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="raw captures directory")
    parser.add_argument("--output", type=Path, required=True, help="scratch / artifact directory")
    parser.add_argument("--no-gs", action="store_true", help="skip Gaussian Splatting")
    parser.add_argument("--matcher", default="sequential", choices=["sequential", "exhaustive"])
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    get_settings()  # trigger env loading & validation
    artifacts = run_pipeline(
        args.input, args.output, enable_gs=not args.no_gs, matcher=args.matcher
    )
    print("pointcloud:", artifacts.pointcloud_ply)
    print("tileset:   ", artifacts.tileset_json)
    print("splat:     ", artifacts.splat_ply)
    print("images:    ", artifacts.image_count)


if __name__ == "__main__":
    _cli()
