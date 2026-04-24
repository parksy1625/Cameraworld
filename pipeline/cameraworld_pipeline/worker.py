"""RQ worker entry point.

Run with ``python -m cameraworld_pipeline.worker``. It listens on the
reconstruction queue, downloads the capture's assets, executes the pipeline,
uploads artifacts, and updates the DB row.
"""

from __future__ import annotations

import logging
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from uuid import UUID

import boto3
import numpy as np
from botocore.client import Config
from plyfile import PlyData  # type: ignore[import-untyped]
from redis import Redis
from rq import Queue, Worker
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from cameraworld_pipeline.config import get_settings
from cameraworld_pipeline.geo.georeference import reconstruction_center
from cameraworld_pipeline.orchestrator import run_pipeline

log = logging.getLogger(__name__)

QUEUE_NAME = "cameraworld-reconstruction"


def _engine():
    return create_engine(get_settings().database_url, future=True, pool_pre_ping=True)


def _session() -> Session:
    return sessionmaker(bind=_engine(), future=True)()


def _s3():
    s = get_settings()
    return boto3.client(
        "s3",
        endpoint_url=s.s3_endpoint,
        aws_access_key_id=s.s3_access_key,
        aws_secret_access_key=s.s3_secret_key,
        region_name=s.s3_region,
        config=Config(signature_version="s3v4"),
    )


def run_reconstruction(capture_id: str, job_id: str) -> None:
    """RQ task — full reconstruction for a single capture."""
    from sqlalchemy import text  # noqa: F401  lazy import inside task

    settings = get_settings()
    log.info("start reconstruction capture=%s job=%s", capture_id, job_id)

    with _session() as db:
        _update_job(db, job_id, status="running", started_at=datetime.now(timezone.utc))

    workdir = Path(tempfile.mkdtemp(prefix=f"cw-{capture_id[:8]}-", dir=settings.pipeline_workdir))
    try:
        Path(settings.pipeline_workdir).mkdir(parents=True, exist_ok=True)
        input_dir = workdir / "input"
        input_dir.mkdir()

        assets = _download_assets(capture_id, input_dir)
        log.info("downloaded %d assets", len(assets))

        def on_stage(stage: str) -> None:
            with _session() as db:
                _update_job(db, job_id, stage=stage)

        artifacts = run_pipeline(input_dir, workdir, enable_gs=True, on_stage=on_stage)

        tileset_key, splat_key, pointcloud_key = _upload_artifacts(capture_id, artifacts)
        geo = _compute_geo(artifacts.pointcloud_ply)

        with _session() as db:
            _create_reconstruction(
                db,
                capture_id=capture_id,
                job_id=job_id,
                tileset_key=tileset_key,
                splat_key=splat_key,
                pointcloud_key=pointcloud_key,
                geo=geo,
            )
            _update_job(
                db,
                job_id,
                status="succeeded",
                stage=None,
                finished_at=datetime.now(timezone.utc),
            )

        log.info("reconstruction complete capture=%s", capture_id)
    except Exception as exc:
        log.exception("reconstruction failed")
        with _session() as db:
            _update_job(
                db,
                job_id,
                status="failed",
                error=str(exc),
                finished_at=datetime.now(timezone.utc),
            )
        raise
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def _download_assets(capture_id: str, dest_dir: Path) -> list[Path]:
    from sqlalchemy import text

    settings = get_settings()
    s3 = _s3()
    paths: list[Path] = []

    with _session() as db:
        rows = db.execute(
            text("SELECT storage_key FROM assets WHERE capture_id = :cid ORDER BY created_at"),
            {"cid": capture_id},
        ).fetchall()

    for (storage_key,) in rows:
        dst = dest_dir / Path(storage_key).name
        s3.download_file(settings.s3_bucket_captures, storage_key, str(dst))
        paths.append(dst)
    return paths


def _upload_artifacts(capture_id: str, artifacts) -> tuple[str, str | None, str]:
    settings = get_settings()
    s3 = _s3()
    bucket = settings.s3_bucket_artifacts

    # Upload tileset directory
    tileset_root = artifacts.tileset_json.parent
    tileset_key = f"{capture_id}/tiles/tileset.json"
    for p in tileset_root.rglob("*"):
        if p.is_file():
            rel = p.relative_to(tileset_root)
            s3.upload_file(str(p), bucket, f"{capture_id}/tiles/{rel.as_posix()}")

    # Point cloud ply
    pointcloud_key = f"{capture_id}/pointcloud.ply"
    s3.upload_file(str(artifacts.pointcloud_ply), bucket, pointcloud_key)

    splat_key: str | None = None
    if artifacts.splat_ply:
        splat_key = f"{capture_id}/scene.splat.ply"
        s3.upload_file(str(artifacts.splat_ply), bucket, splat_key)

    return tileset_key, splat_key, pointcloud_key


def _compute_geo(ply_path: Path):
    """Load a PLY point cloud and compute its geo center (assumes ECEF coords)."""
    try:
        data = PlyData.read(str(ply_path))
        v = data["vertex"]
        points = np.vstack([v["x"], v["y"], v["z"]]).T
        # If the reconstruction is not georeferenced, points are in local frame.
        # We mark geo as None so the UI falls back to manual placement.
        if np.linalg.norm(points.mean(axis=0)) < 1e5:
            return None
        return reconstruction_center(points)
    except Exception as exc:  # pragma: no cover — defensive
        log.warning("geo extraction failed: %s", exc)
        return None


def _update_job(
    db: Session,
    job_id: str,
    *,
    status: str | None = None,
    stage: str | None = None,
    error: str | None = None,
    started_at: datetime | None = None,
    finished_at: datetime | None = None,
) -> None:
    from sqlalchemy import text

    updates: dict = {}
    if status is not None:
        updates["status"] = status
    if stage is not None or status == "succeeded":
        updates["stage"] = stage
    if error is not None:
        updates["error"] = error
    if started_at is not None:
        updates["started_at"] = started_at
    if finished_at is not None:
        updates["finished_at"] = finished_at
    if not updates:
        return

    set_clause = ", ".join(f"{k} = :{k}" for k in updates)
    updates["id"] = UUID(job_id)
    db.execute(text(f"UPDATE jobs SET {set_clause} WHERE id = :id"), updates)
    db.commit()


def _create_reconstruction(
    db: Session,
    *,
    capture_id: str,
    job_id: str,
    tileset_key: str,
    splat_key: str | None,
    pointcloud_key: str,
    geo,
) -> None:
    from sqlalchemy import text

    db.execute(
        text(
            """
            INSERT INTO reconstructions
                (id, capture_id, job_id, tileset_key, splat_key, pointcloud_key,
                 center_lat, center_lon, center_alt, radius_m)
            VALUES
                (gen_random_uuid(), :cid, :jid, :tkey, :skey, :pkey,
                 :clat, :clon, :calt, :rad)
            """
        ),
        {
            "cid": UUID(capture_id),
            "jid": UUID(job_id),
            "tkey": tileset_key,
            "skey": splat_key,
            "pkey": pointcloud_key,
            "clat": geo.lat if geo else None,
            "clon": geo.lon if geo else None,
            "calt": geo.alt if geo else None,
            "rad": geo.radius_m if geo else None,
        },
    )
    db.commit()


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    conn = Redis.from_url(get_settings().redis_url)
    queue = Queue(QUEUE_NAME, connection=conn)
    worker = Worker([queue], connection=conn)
    log.info("cameraworld worker listening on %s", QUEUE_NAME)
    worker.work(with_scheduler=False)


if __name__ == "__main__":
    main()
