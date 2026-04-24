"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-04-24 00:00:00

"""
import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "captures",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("region_id", sa.String(128), nullable=False, index=True),
        sa.Column("user_id", sa.String(128), nullable=False, index=True),
        sa.Column("lat_min", sa.Float),
        sa.Column("lat_max", sa.Float),
        sa.Column("lon_min", sa.Float),
        sa.Column("lon_max", sa.Float),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.Column("submitted_at", sa.DateTime(timezone=True)),
    )

    op.create_table(
        "assets",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            index=True,
            nullable=False,
        ),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("storage_key", sa.String(512), nullable=False),
        sa.Column("content_type", sa.String(128), nullable=False),
        sa.Column("size_bytes", sa.BigInteger, default=0),
        sa.Column("lat", sa.Float),
        sa.Column("lon", sa.Float),
        sa.Column("altitude", sa.Float),
        sa.Column("heading", sa.Float),
        sa.Column("captured_at", sa.DateTime(timezone=True)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    )

    job_status = sa.Enum("queued", "running", "succeeded", "failed", name="job_status")
    job_status.create(op.get_bind(), checkfirst=True)

    op.create_table(
        "jobs",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            index=True,
            nullable=False,
        ),
        sa.Column("status", job_status, nullable=False, server_default="queued", index=True),
        sa.Column("stage", sa.String(64)),
        sa.Column("error", sa.Text),
        sa.Column("rq_job_id", sa.String(64)),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
        sa.Column("started_at", sa.DateTime(timezone=True)),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
    )

    op.create_table(
        "reconstructions",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column(
            "capture_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            index=True,
            nullable=False,
        ),
        sa.Column(
            "job_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("jobs.id", ondelete="CASCADE"),
            index=True,
            nullable=False,
        ),
        sa.Column("tileset_key", sa.String(512)),
        sa.Column("splat_key", sa.String(512)),
        sa.Column("pointcloud_key", sa.String(512)),
        sa.Column("center_lat", sa.Float),
        sa.Column("center_lon", sa.Float),
        sa.Column("center_alt", sa.Float),
        sa.Column("radius_m", sa.Float),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()")),
    )


def downgrade() -> None:
    op.drop_table("reconstructions")
    op.drop_table("jobs")
    sa.Enum(name="job_status").drop(op.get_bind(), checkfirst=True)
    op.drop_table("assets")
    op.drop_table("captures")
