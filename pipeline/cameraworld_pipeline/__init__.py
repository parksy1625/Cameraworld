"""Cameraworld reconstruction pipeline.

The orchestrator chains stages:
    extract_frames -> filter_quality -> colmap_sfm -> colmap_mvs
    -> gaussian_splat -> to_3dtiles
"""

__version__ = "0.1.0"
