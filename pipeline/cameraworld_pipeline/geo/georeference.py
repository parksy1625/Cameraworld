"""Lightweight geo-reference helpers for the MVP.

We use ``pyproj`` to convert lat/lon/alt (WGS84) to ECEF meters and back.
This matches what Cesium expects for 3D Tiles ``boundingVolume.box`` centers.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from pyproj import Transformer

_LLA_TO_ECEF = Transformer.from_crs("EPSG:4979", "EPSG:4978", always_xy=True)
_ECEF_TO_LLA = Transformer.from_crs("EPSG:4978", "EPSG:4979", always_xy=True)


@dataclass
class GeoCenter:
    lat: float
    lon: float
    alt: float
    radius_m: float


def ecef_from_lla(lat: float, lon: float, alt: float = 0.0) -> tuple[float, float, float]:
    x, y, z = _LLA_TO_ECEF.transform(lon, lat, alt)
    return float(x), float(y), float(z)


def lla_from_ecef(x: float, y: float, z: float) -> tuple[float, float, float]:
    lon, lat, alt = _ECEF_TO_LLA.transform(x, y, z)
    return float(lat), float(lon), float(alt)


def reconstruction_center(ecef_points: np.ndarray) -> GeoCenter:
    """Compute centroid and bounding radius from an ECEF point array (N, 3)."""
    if ecef_points.size == 0:
        raise ValueError("empty point cloud")
    centroid = ecef_points.mean(axis=0)
    radius = float(np.linalg.norm(ecef_points - centroid, axis=1).max())
    lat, lon, alt = lla_from_ecef(*centroid)
    return GeoCenter(lat=lat, lon=lon, alt=alt, radius_m=radius)
