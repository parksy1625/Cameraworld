"""Convert a dense point cloud (.ply) into a Cesium 3D Tiles tileset."""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

log = logging.getLogger(__name__)


def run(pointcloud_ply: Path, output_dir: Path) -> Path:
    """Convert a PLY point cloud into 3D Tiles using py3dtiles.

    Returns:
        Path to ``tileset.json``.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        "py3dtiles",
        "convert",
        str(pointcloud_ply),
        "--out",
        str(output_dir),
        "--overwrite",
    ]
    log.info("py3dtiles: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)

    tileset = output_dir / "tileset.json"
    if not tileset.exists():
        raise RuntimeError(f"py3dtiles produced no tileset.json at {tileset}")
    return tileset
