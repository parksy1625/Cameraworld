import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_db
from app.models import Asset, Capture, Job, JobStatus, Reconstruction
from app.queue import enqueue_reconstruction
from app.schemas.capture import (
    AssetRead,
    AssetRegister,
    CaptureCreate,
    CaptureRead,
    JobRead,
    PresignRequest,
    PresignResponse,
    ReconstructionRead,
)
from app.storage import get_storage

router = APIRouter()


@router.post("", response_model=CaptureRead, status_code=status.HTTP_201_CREATED)
def create_capture(payload: CaptureCreate, db: Session = Depends(get_db)) -> Capture:
    capture = Capture(**payload.model_dump())
    db.add(capture)
    db.commit()
    db.refresh(capture)
    return capture


@router.get("/{capture_id}", response_model=CaptureRead)
def get_capture(capture_id: uuid.UUID, db: Session = Depends(get_db)) -> Capture:
    capture = db.get(Capture, capture_id)
    if not capture:
        raise HTTPException(status_code=404, detail="capture not found")
    return capture


@router.post("/{capture_id}/assets/presign", response_model=PresignResponse)
def presign_asset(
    capture_id: uuid.UUID, payload: PresignRequest, db: Session = Depends(get_db)
) -> PresignResponse:
    if not db.get(Capture, capture_id):
        raise HTTPException(status_code=404, detail="capture not found")

    settings = get_settings()
    storage_key = f"{capture_id}/{uuid.uuid4()}_{payload.filename}"
    upload_url = get_storage().presigned_put(
        settings.s3_bucket_captures, storage_key, payload.content_type
    )
    return PresignResponse(storage_key=storage_key, upload_url=upload_url, expires_in=3600)


@router.post("/{capture_id}/assets", response_model=AssetRead, status_code=status.HTTP_201_CREATED)
def register_asset(
    capture_id: uuid.UUID, payload: AssetRegister, db: Session = Depends(get_db)
) -> Asset:
    capture = db.get(Capture, capture_id)
    if not capture:
        raise HTTPException(status_code=404, detail="capture not found")

    asset = Asset(capture_id=capture_id, **payload.model_dump())
    db.add(asset)
    db.commit()
    db.refresh(asset)
    return asset


@router.get("/{capture_id}/assets", response_model=list[AssetRead])
def list_assets(capture_id: uuid.UUID, db: Session = Depends(get_db)) -> list[Asset]:
    if not db.get(Capture, capture_id):
        raise HTTPException(status_code=404, detail="capture not found")
    return (
        db.query(Asset).filter(Asset.capture_id == capture_id).order_by(Asset.created_at).all()
    )


@router.post("/{capture_id}/submit", response_model=JobRead, status_code=status.HTTP_202_ACCEPTED)
def submit_capture(capture_id: uuid.UUID, db: Session = Depends(get_db)) -> Job:
    capture = db.get(Capture, capture_id)
    if not capture:
        raise HTTPException(status_code=404, detail="capture not found")

    n_assets = db.query(Asset).filter(Asset.capture_id == capture_id).count()
    if n_assets < 5:
        raise HTTPException(
            status_code=400,
            detail=f"need at least 5 assets to reconstruct (have {n_assets})",
        )

    job = Job(capture_id=capture_id, status=JobStatus.QUEUED)
    db.add(job)
    capture.submitted_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(job)

    rq_job_id = enqueue_reconstruction(capture_id, job.id)
    job.rq_job_id = rq_job_id
    db.commit()
    return job


@router.get("/{capture_id}/jobs", response_model=list[JobRead])
def list_jobs(capture_id: uuid.UUID, db: Session = Depends(get_db)) -> list[Job]:
    return db.query(Job).filter(Job.capture_id == capture_id).order_by(Job.created_at.desc()).all()


@router.get("/{capture_id}/reconstruction", response_model=ReconstructionRead)
def get_reconstruction(capture_id: uuid.UUID, db: Session = Depends(get_db)) -> ReconstructionRead:
    rec = (
        db.query(Reconstruction)
        .filter(Reconstruction.capture_id == capture_id)
        .order_by(Reconstruction.created_at.desc())
        .first()
    )
    if not rec:
        raise HTTPException(status_code=404, detail="no reconstruction yet")

    settings = get_settings()
    storage = get_storage()
    bucket = settings.s3_bucket_artifacts

    def url(key: str | None) -> str | None:
        return storage.presigned_get(bucket, key) if key else None

    return ReconstructionRead(
        id=rec.id,
        capture_id=rec.capture_id,
        job_id=rec.job_id,
        tileset_url=url(rec.tileset_key),
        splat_url=url(rec.splat_key),
        pointcloud_url=url(rec.pointcloud_key),
        center_lat=rec.center_lat,
        center_lon=rec.center_lon,
        center_alt=rec.center_alt,
        radius_m=rec.radius_m,
        created_at=rec.created_at,
    )
