import pytest

from app.schemas.capture import AssetRegister, CaptureCreate


def test_capture_create_bbox_optional() -> None:
    c = CaptureCreate(region_id="r1", user_id="u1")
    assert c.lat_min is None


def test_asset_kind_validated() -> None:
    with pytest.raises(ValueError):
        AssetRegister(kind="audio", storage_key="k", content_type="a/b", size_bytes=0)

    a = AssetRegister(kind="photo", storage_key="k", content_type="image/jpeg", size_bytes=1000)
    assert a.kind == "photo"
