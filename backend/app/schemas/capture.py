from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field


class CaptureCreate(BaseModel):
    region_id: str = Field(..., max_length=128)
    user_id: str = Field(..., max_length=128)
    lat_min: float | None = None
    lat_max: float | None = None
    lon_min: float | None = None
    lon_max: float | None = None


class CaptureRead(BaseModel):
    id: UUID
    region_id: str
    user_id: str
    lat_min: float | None
    lat_max: float | None
    lon_min: float | None
    lon_max: float | None
    created_at: datetime
    submitted_at: datetime | None

    class Config:
        from_attributes = True


class AssetRegister(BaseModel):
    """Register an asset after client uploads via presigned URL."""

    kind: str = Field(..., pattern="^(photo|video)$")
    storage_key: str
    content_type: str
    size_bytes: int
    lat: float | None = None
    lon: float | None = None
    altitude: float | None = None
    heading: float | None = None
    captured_at: datetime | None = None


class AssetRead(BaseModel):
    id: UUID
    kind: str
    storage_key: str
    content_type: str
    size_bytes: int

    class Config:
        from_attributes = True


class PresignRequest(BaseModel):
    kind: str = Field(..., pattern="^(photo|video)$")
    content_type: str
    filename: str


class PresignResponse(BaseModel):
    storage_key: str
    upload_url: str
    expires_in: int


class JobRead(BaseModel):
    id: UUID
    capture_id: UUID
    status: str
    stage: str | None
    error: str | None
    created_at: datetime
    started_at: datetime | None
    finished_at: datetime | None

    class Config:
        from_attributes = True


class ReconstructionRead(BaseModel):
    id: UUID
    capture_id: UUID
    job_id: UUID
    tileset_url: str | None
    splat_url: str | None
    pointcloud_url: str | None
    center_lat: float | None
    center_lon: float | None
    center_alt: float | None
    radius_m: float | None
    created_at: datetime
