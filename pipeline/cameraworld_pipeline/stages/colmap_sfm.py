"""Structure-from-Motion with COLMAP.

Produces a sparse reconstruction (camera poses + sparse point cloud) in
`<workdir>/sparse/0/` which downstream MVS and Gaussian Splatting stages consume.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)


def run(image_dir: Path, workdir: Path, matcher: str = "sequential") -> Path:
    """Run COLMAP SfM on ``image_dir``.

    Args:
        image_dir: Directory of prepared images.
        workdir: Scratch directory; sparse model ends up at workdir/sparse.
        matcher: "sequential" for video-like captures, "exhaustive" for scattered photos.

    Returns:
        Path to the sparse model directory (``workdir/sparse/0``).
    """
    settings = get_settings()
    colmap = settings.colmap_bin

    db_path = workdir / "database.db"
    sparse_dir = workdir / "sparse"
    sparse_dir.mkdir(parents=True, exist_ok=True)

    # 1. feature extraction
    _run([
        colmap, "feature_extractor",
        "--database_path", str(db_path),
        "--image_path", str(image_dir),
        "--ImageReader.single_camera", "1",
        "--SiftExtraction.use_gpu", "1",
    ])

    # 2. matcher
    matcher_cmd = {
        "sequential": "sequential_matcher",
        "exhaustive": "exhaustive_matcher",
        "vocab_tree": "vocab_tree_matcher",
    }[matcher]
    _run([colmap, matcher_cmd, "--database_path", str(db_path), "--SiftMatching.use_gpu", "1"])

    # 3. mapper
    _run([
        colmap, "mapper",
        "--database_path", str(db_path),
        "--image_path", str(image_dir),
        "--output_path", str(sparse_dir),
    ])

    model_dir = sparse_dir / "0"
    if not model_dir.exists():
        raise RuntimeError(f"COLMAP mapper produced no model at {model_dir}")
    log.info("sparse model ready at %s", model_dir)
    return model_dir


def align_to_geo(sparse_dir: Path, geo_csv: Path) -> Path:
    """Align a COLMAP sparse model to an ECEF geo reference using model_aligner.

    ``geo_csv`` must contain ``image_name,x,y,z`` rows in ECEF meters.
    """
    settings = get_settings()
    aligned = sparse_dir.parent / "aligned"
    aligned.mkdir(parents=True, exist_ok=True)
    _run([
        settings.colmap_bin, "model_aligner",
        "--input_path", str(sparse_dir),
        "--output_path", str(aligned),
        "--ref_images_path", str(geo_csv),
        "--ref_is_gps", "0",
        "--robust_alignment", "1",
        "--robust_alignment_max_error", "3.0",
    ])
    return aligned


def _run(cmd: list[str]) -> None:
    log.info("colmap: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)
