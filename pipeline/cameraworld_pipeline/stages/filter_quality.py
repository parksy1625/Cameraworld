"""Filter out blurry and near-duplicate images before feeding COLMAP."""

from __future__ import annotations

import logging
from pathlib import Path

import cv2
import imagehash
import numpy as np
from PIL import Image

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)


def laplacian_sharpness(image_path: Path) -> float:
    """Return the Laplacian variance. Higher = sharper."""
    img = cv2.imread(str(image_path), cv2.IMREAD_GRAYSCALE)
    if img is None:
        return 0.0
    return float(cv2.Laplacian(img, cv2.CV_64F).var())


def run(
    image_dir: Path,
    blur_threshold: float | None = None,
    hamming_threshold: int = 4,
    max_dim: int | None = None,
) -> list[Path]:
    """Drop blurry / duplicate images in place; return surviving paths.

    Args:
        image_dir: Directory of candidate images.
        blur_threshold: Minimum Laplacian variance. Below = drop.
        hamming_threshold: Max perceptual-hash hamming distance to treat as duplicate.
        max_dim: If set, resize images larger than this on their longest side.

    Returns:
        Sorted list of surviving image paths.
    """
    settings = get_settings()
    blur_threshold = blur_threshold if blur_threshold is not None else settings.pipeline_blur_threshold
    max_dim = max_dim if max_dim is not None else settings.pipeline_max_image_dim

    candidates = sorted(
        p for p in image_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    if not candidates:
        return []

    kept: list[Path] = []
    kept_hashes: list[imagehash.ImageHash] = []

    for path in candidates:
        sharpness = laplacian_sharpness(path)
        if sharpness < blur_threshold:
            log.info("drop blurry %s (var=%.1f)", path.name, sharpness)
            path.unlink(missing_ok=True)
            continue

        try:
            with Image.open(path) as im:
                phash = imagehash.phash(im)
                if max_dim and max(im.size) > max_dim:
                    im.thumbnail((max_dim, max_dim), Image.LANCZOS)
                    im.save(path, quality=92)
        except Exception as e:  # pragma: no cover — Pillow raises many types
            log.warning("cannot open %s: %s", path, e)
            path.unlink(missing_ok=True)
            continue

        if any(abs(phash - h) <= hamming_threshold for h in kept_hashes):
            log.info("drop duplicate %s", path.name)
            path.unlink(missing_ok=True)
            continue

        kept.append(path)
        kept_hashes.append(phash)

    log.info("quality filter: kept %d / %d", len(kept), len(candidates))
    return kept


def summarize(image_dir: Path) -> dict:
    """Return summary stats useful for job logs."""
    images = [p for p in image_dir.iterdir() if p.suffix.lower() in {".jpg", ".jpeg", ".png"}]
    if not images:
        return {"count": 0, "mean_sharpness": 0.0}
    sharps = [laplacian_sharpness(p) for p in images]
    return {
        "count": len(images),
        "mean_sharpness": float(np.mean(sharps)),
        "min_sharpness": float(np.min(sharps)),
    }
