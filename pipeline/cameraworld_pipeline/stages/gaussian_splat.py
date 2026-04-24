"""Train a 3D Gaussian Splatting model on a COLMAP reconstruction.

Uses the reference INRIA implementation from
https://github.com/graphdeco-inria/gaussian-splatting (cloned into
``GS_REPO_PATH``). The trained splats end up at ``<output>/point_cloud/iteration_N/point_cloud.ply``
in the upstream format.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)


def run(
    colmap_workdir: Path,
    output_dir: Path,
    iterations: int | None = None,
) -> Path:
    """Train Gaussian Splats and return the produced ``.ply`` path.

    Args:
        colmap_workdir: Workdir containing ``images/`` and ``sparse/0/`` (COLMAP format).
        output_dir: Where GS training artifacts are written.
        iterations: Override training iterations.
    """
    settings = get_settings()
    iterations = iterations if iterations is not None else settings.pipeline_gs_iterations
    output_dir.mkdir(parents=True, exist_ok=True)

    train_py = Path(settings.gs_repo_path) / "train.py"
    if not train_py.exists():
        raise RuntimeError(
            f"gaussian-splatting repo not found at {settings.gs_repo_path}. "
            "Clone https://github.com/graphdeco-inria/gaussian-splatting or set GS_REPO_PATH."
        )

    cmd = [
        "python",
        str(train_py),
        "-s",
        str(colmap_workdir),
        "-m",
        str(output_dir),
        "--iterations",
        str(iterations),
    ]
    log.info("gs train: %s", " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=settings.gs_repo_path)

    iter_dirs = sorted((output_dir / "point_cloud").glob("iteration_*"))
    if not iter_dirs:
        raise RuntimeError(f"GS training produced no output in {output_dir}")
    ply = iter_dirs[-1] / "point_cloud.ply"
    if not ply.exists():
        raise RuntimeError(f"expected splat ply at {ply}")
    log.info("gaussian splats at %s", ply)
    return ply


def copy_to_artifact(ply: Path, artifact_path: Path) -> Path:
    """Copy a trained splat ply to the final artifact path."""
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ply, artifact_path)
    return artifact_path
