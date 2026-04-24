import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, String, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


class Capture(Base):
    __tablename__ = "captures"

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    region_id: Mapped[str] = mapped_column(String(128), index=True)
    user_id: Mapped[str] = mapped_column(String(128), index=True)

    lat_min: Mapped[float | None] = mapped_column(Float, nullable=True)
    lat_max: Mapped[float | None] = mapped_column(Float, nullable=True)
    lon_min: Mapped[float | None] = mapped_column(Float, nullable=True)
    lon_max: Mapped[float | None] = mapped_column(Float, nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    submitted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    assets = relationship("Asset", back_populates="capture", cascade="all, delete-orphan")
    jobs = relationship("Job", back_populates="capture", cascade="all, delete-orphan")
