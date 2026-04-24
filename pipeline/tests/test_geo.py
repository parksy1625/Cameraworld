import numpy as np

from cameraworld_pipeline.geo.georeference import (
    ecef_from_lla,
    lla_from_ecef,
    reconstruction_center,
)


def test_lla_ecef_roundtrip() -> None:
    # Seoul City Hall
    lat, lon, alt = 37.5663, 126.9779, 38.0
    x, y, z = ecef_from_lla(lat, lon, alt)
    lat2, lon2, alt2 = lla_from_ecef(x, y, z)
    assert abs(lat - lat2) < 1e-6
    assert abs(lon - lon2) < 1e-6
    assert abs(alt - alt2) < 1e-2


def test_reconstruction_center_small_region() -> None:
    center = np.array(ecef_from_lla(37.5663, 126.9779, 38.0))
    # 100 random points within ~10m
    pts = center + np.random.default_rng(42).normal(0, 5, size=(100, 3))
    gc = reconstruction_center(pts)
    assert abs(gc.lat - 37.5663) < 1e-3
    assert abs(gc.lon - 126.9779) < 1e-3
    assert 0 < gc.radius_m < 50
