"""Extract still frames from input videos using ffmpeg.

Photos pass through unchanged. Videos are sampled at a fixed FPS and
optionally filtered by scene-change detection.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path

from cameraworld_pipeline.config import get_settings

log = logging.getLogger(__name__)

VIDEO_SUFFIXES = {".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm"}
PHOTO_SUFFIXES = {".jpg", ".jpeg", ".png", ".heic", ".webp"}


def run(input_dir: Path, output_dir: Path, fps: float | None = None) -> list[Path]:
    """Normalise a mixed photo/video input folder into a flat images folder.

    Args:
        input_dir: Directory containing photos and/or videos (flat).
        output_dir: Destination image directory (created if needed).
        fps: Sampling rate for videos. Defaults to pipeline setting.

    Returns:
        List of image paths written to output_dir.
    """
    settings = get_settings()
    fps = fps if fps is not None else settings.pipeline_frame_fps
    output_dir.mkdir(parents=True, exist_ok=True)

    written: list[Path] = []

    for src in sorted(input_dir.iterdir()):
        suffix = src.suffix.lower()
        if suffix in PHOTO_SUFFIXES:
            dst = output_dir / f"photo_{src.stem}{suffix}"
            shutil.copy2(src, dst)
            written.append(dst)
        elif suffix in VIDEO_SUFFIXES:
            written.extend(_extract_video(src, output_dir, fps, settings.ffmpeg_bin))
        else:
            log.warning("skipping unsupported file: %s", src.name)

    log.info("extracted %d frames from %s", len(written), input_dir)
    return written


def _extract_video(video: Path, output_dir: Path, fps: float, ffmpeg: str) -> list[Path]:
    pattern = output_dir / f"video_{video.stem}_%05d.jpg"
    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-i",
        str(video),
        "-vf",
        f"fps={fps}",
        "-q:v",
        "2",
        str(pattern),
    ]
    log.info("ffmpeg: %s", " ".join(cmd))
    subprocess.run(cmd, check=True)
    return sorted(output_dir.glob(f"video_{video.stem}_*.jpg"))
