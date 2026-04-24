from pathlib import Path

import numpy as np
import pytest
from PIL import Image


@pytest.fixture
def sharp_image(tmp_path):
    """Create a high-contrast image with sharp edges — passes the blur filter."""

    def _make(name: str = "sharp.jpg", size: int = 256) -> Path:
        arr = np.zeros((size, size, 3), dtype=np.uint8)
        arr[:, : size // 2] = 255  # hard vertical edge
        arr[::8, :] = 255  # stripes for extra variance
        path = tmp_path / name
        Image.fromarray(arr).save(path, quality=95)
        return path

    return _make


@pytest.fixture
def blurry_image(tmp_path):
    def _make(name: str = "blur.jpg", size: int = 256) -> Path:
        arr = np.full((size, size, 3), 128, dtype=np.uint8)  # solid gray
        path = tmp_path / name
        Image.fromarray(arr).save(path, quality=85)
        return path

    return _make
