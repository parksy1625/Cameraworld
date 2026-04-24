"""Dense reconstruction with COLMAP MVS (image_undistorter + patch_match + fusion)."""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)


def run(image_dir: Path, sparse_dir: Path, workdir: Path) -> Path:
    """Produce a dense fused point cloud.

    Returns:
        Path to ``fused.ply``.
    """
    settings = get_settings()
    colmap = settings.colmap_bin

    dense_dir = workdir / "dense"
    dense_dir.mkdir(parents=True, exist_ok=True)

    _run([
        colmap, "image_undistorter",
        "--image_path", str(image_dir),
        "--input_path", str(sparse_dir),
        "--output_path", str(dense_dir),
        "--output_type", "COLMAP",
        "--max_image_size", str(settings.pipeline_max_image_dim),
    ])

    _run([
        colmap, "patch_match_stereo",
        "--workspace_path", str(dense_dir),
        "--workspace_format", "COLMAP",
        "--PatchMatchStereo.geom_consistency", "true",
    ])

    fused = dense_dir / "fused.ply"
    _run([
        colmap, "stereo_fusion",
        "--workspace_path", str(dense_dir),
        "--workspace_format", "COLMAP",
        "--input_type", "geometric",
        "--output_path", str(fused),
    ])

    if not fused.exists():
        raise RuntimeError(f"stereo_fusion produced no ply at {fused}")
    log.info("dense point cloud at %s", fused)
    return fused


def _run(cmd: list[str]) -> None:
    log.info("colmap: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)
