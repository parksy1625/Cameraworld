"""Structure-from-Motion with COLMAP.

Produces a sparse reconstruction (camera poses + sparse point cloud) in
`<workdir>/sparse/0/` which downstream MVS and Gaussian Splatting stages consume.

Two parameter presets are provided — ``outdoor`` (COLMAP defaults) and
``indoor`` (lower peak threshold, higher edge threshold, relaxed mapper
init). Indoor scenes suffer from low-texture surfaces (plain walls) and
fewer extractable features, so the indoor preset opts for quantity over
quality and tolerates smaller feature tracks. If the default preset
fails to produce a mapper model, we retry once with the indoor preset
before bailing out — this makes the pipeline resilient to the typical
"room with one textured poster on the wall" capture.
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)


_OUTDOOR_FEATURE_ARGS = [
    # COLMAP defaults — retained here for clarity.
    "--SiftExtraction.peak_threshold", "0.0066",
    "--SiftExtraction.edge_threshold", "10",
    "--SiftExtraction.max_num_features", "8192",
]
_INDOOR_FEATURE_ARGS = [
    # More permissive: pull more weak features from low-texture surfaces.
    "--SiftExtraction.peak_threshold", "0.002",
    "--SiftExtraction.edge_threshold", "30",
    "--SiftExtraction.max_num_features", "16384",
]

_OUTDOOR_MAPPER_ARGS: list[str] = []
_INDOOR_MAPPER_ARGS = [
    # Let the reconstruction bootstrap from smaller image pairs and short tracks.
    "--Mapper.init_min_num_inliers", "50",
    "--Mapper.abs_pose_min_num_inliers", "10",
    "--Mapper.filter_min_tri_angle", "1.0",
    "--Mapper.tri_min_angle", "1.0",
]


def run(
    image_dir: Path,
    workdir: Path,
    matcher: str = "sequential",
    scene_hint: str = "auto",
) -> Path:
    """Run COLMAP SfM on ``image_dir``.

    Args:
        image_dir: Directory of prepared images.
        workdir: Scratch directory; sparse model ends up at ``workdir/sparse``.
        matcher: ``"sequential"`` for video-like captures, ``"exhaustive"`` for
            scattered photos, ``"vocab_tree"`` for large collections.
        scene_hint: ``"outdoor"``, ``"indoor"``, or ``"auto"``. ``"auto"`` tries
            outdoor parameters first and falls back to indoor if the mapper
            produces no model.

    Returns:
        Path to the sparse model directory (``workdir/sparse/0``).
    """
    preset = scene_hint if scene_hint in {"outdoor", "indoor"} else "outdoor"
    try:
        return _try_preset(image_dir, workdir, matcher, preset)
    except RuntimeError as exc:
        if scene_hint == "auto" and preset == "outdoor":
            log.warning("outdoor SfM failed (%s); retrying with indoor preset", exc)
            return _try_preset(image_dir, workdir, matcher, "indoor", retry=True)
        raise


def _try_preset(
    image_dir: Path, workdir: Path, matcher: str, preset: str, *, retry: bool = False
) -> Path:
    settings = get_settings()
    colmap = settings.colmap_bin
    suffix = "_retry" if retry else ""
    db_path = workdir / f"database{suffix}.db"
    sparse_dir = workdir / f"sparse{suffix}"
    sparse_dir.mkdir(parents=True, exist_ok=True)

    feature_args = _INDOOR_FEATURE_ARGS if preset == "indoor" else _OUTDOOR_FEATURE_ARGS
    mapper_args = _INDOOR_MAPPER_ARGS if preset == "indoor" else _OUTDOOR_MAPPER_ARGS
    log.info("COLMAP SfM preset=%s matcher=%s", preset, matcher)

    _run([
        colmap, "feature_extractor",
        "--database_path", str(db_path),
        "--image_path", str(image_dir),
        "--ImageReader.single_camera", "1",
        "--SiftExtraction.use_gpu", "1",
        *feature_args,
    ])

    matcher_cmd = {
        "sequential": "sequential_matcher",
        "exhaustive": "exhaustive_matcher",
        "vocab_tree": "vocab_tree_matcher",
    }[matcher]
    _run([colmap, matcher_cmd, "--database_path", str(db_path), "--SiftMatching.use_gpu", "1"])

    _run([
        colmap, "mapper",
        "--database_path", str(db_path),
        "--image_path", str(image_dir),
        "--output_path", str(sparse_dir),
        *mapper_args,
    ])

    model_dir = sparse_dir / "0"
    if not model_dir.exists():
        raise RuntimeError(f"COLMAP mapper produced no model at {model_dir}")
    log.info("sparse model ready at %s", model_dir)
    return model_dir


def align_to_geo(sparse_dir: Path, geo_csv: Path) -> Path:
    """Align a COLMAP sparse model to an ECEF geo reference using ``model_aligner``.

    ``geo_csv`` must contain ``image_name x y z`` rows in ECEF meters. Called
    by the orchestrator whenever at least three source images had GPS
    metadata (see ``orchestrator.MIN_GEO_REFERENCES``).
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
