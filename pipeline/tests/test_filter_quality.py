from pathlib import Path

from cameraworld_pipeline.stages import filter_quality


def test_blurry_images_dropped(tmp_path: Path, sharp_image, blurry_image) -> None:
    sharp_image("a.jpg")
    sharp_image("b.jpg")
    blurry_image("c.jpg")
    blurry_image("d.jpg")

    kept = filter_quality.run(tmp_path, blur_threshold=50, hamming_threshold=0)
    names = sorted(p.name for p in kept)
    assert "c.jpg" not in names
    assert "d.jpg" not in names


def test_duplicates_collapsed(tmp_path: Path, sharp_image) -> None:
    # Same content under different names — pHash should collapse them.
    sharp_image("one.jpg")
    sharp_image("two.jpg")
    kept = filter_quality.run(tmp_path, blur_threshold=10, hamming_threshold=4)
    assert len(kept) == 1


def test_laplacian_monotonic(tmp_path: Path, sharp_image, blurry_image) -> None:
    sharp = filter_quality.laplacian_sharpness(sharp_image("s.jpg"))
    blurry = filter_quality.laplacian_sharpness(blurry_image("b.jpg"))
    assert sharp > blurry
