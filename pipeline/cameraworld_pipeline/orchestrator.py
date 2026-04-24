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
from cameraworld_pipeline.geo.georeference import ecef_from_lla
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

# Minimum number of images with GPS to attempt geo-alignment via
# COLMAP's model_aligner. Fewer than this means the result is unreliable
# (degenerate rigid transform), so we keep the reconstruction in local
# coordinates and let the viewer fall back to a manual pin.
MIN_GEO_REFERENCES = 3


@dataclass
class Artifacts:
    pointcloud_ply: Path
    tileset_json: Path
    splat_ply: Path | None
    image_count: int
    geo_aligned: bool


def run_pipeline(
    input_dir: Path,
    workdir: Path,
    enable_gs: bool = True,
    matcher: str = "sequential",
    on_stage: callable | None = None,
    geo_points: dict[str, tuple[float, float, float]] | None = None,
    scene_hint: str = "auto",
) -> Artifacts:
    """Execute the full pipeline.

    Args:
        input_dir: Raw inputs (photos and/or videos, flat layout).
        workdir: Scratch directory; will be populated with intermediate artifacts.
        enable_gs: If False, skip Gaussian Splatting training.
        matcher: COLMAP matcher: "sequential" for continuous video, "exhaustive" for photos.
        on_stage: Optional callback invoked as ``on_stage(stage_name)`` before each stage
            (used by the worker to persist progress).
        geo_points: Optional ``{filename: (lat, lon, alt)}`` mapping. When
            at least ``MIN_GEO_REFERENCES`` entries match the actual image
            filenames, COLMAP ``model_aligner`` transforms the sparse model
            into ECEF so downstream artifacts are placed on the real globe.
        scene_hint: ``"outdoor"`` (exhaustive matcher, standard feature params),
            ``"indoor"`` (lower feature thresholds, higher dupe tolerance,
            relaxed mapper init), or ``"auto"`` (passed through to the SfM
            stage which picks based on the matcher).
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
    sparse_dir = colmap_sfm.run(
        images_dir, workdir, matcher=matcher, scene_hint=scene_hint
    )

    geo_aligned = False
    if geo_points:
        geo_csv = _write_geo_csv(images_dir, geo_points, workdir / "geo_ecef.csv")
        if geo_csv is not None:
            try:
                sparse_dir = colmap_sfm.align_to_geo(sparse_dir, geo_csv)
                geo_aligned = True
                log.info("sparse model aligned to ECEF via %d references", geo_csv.stat().st_size)
            except Exception as exc:
                log.warning("geo alignment failed, falling back to local coords: %s", exc)
        else:
            log.info("skipping geo alignment: fewer than %d images with GPS", MIN_GEO_REFERENCES)

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
        geo_aligned=geo_aligned,
    )


def _write_geo_csv(
    images_dir: Path,
    geo_points: dict[str, tuple[float, float, float]],
    out_path: Path,
) -> Path | None:
    """Translate ``{filename: (lat, lon, alt)}`` into a COLMAP ``model_aligner``
    reference file (``image_name x y z`` in ECEF meters). Returns None if
    fewer than MIN_GEO_REFERENCES images have usable coordinates."""
    existing = {p.name for p in images_dir.iterdir() if p.is_file()}
    rows: list[str] = []
    for name, (lat, lon, alt) in geo_points.items():
        if name not in existing:
            # Maybe the source was a video; try matching the stem prefix.
            matches = [n for n in existing if n.startswith(f"photo_{Path(name).stem}")]
            if not matches:
                continue
            name = matches[0]
        x, y, z = ecef_from_lla(lat, lon, alt or 0.0)
        rows.append(f"{name} {x:.4f} {y:.4f} {z:.4f}")

    if len(rows) < MIN_GEO_REFERENCES:
        return None

    out_path.write_text("\n".join(rows) + "\n")
    return out_path


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
