import os
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, String, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


class Base(DeclarativeBase):
    pass


class Job(Base):
    __tablename__ = "prediction_jobs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    status: Mapped[str] = mapped_column(String(20), default="queued")
    features: Mapped[list] = mapped_column(JSON)
    result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    error: Mapped[str | None] = mapped_column(String(500), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


engine = create_engine(
    os.getenv("DATABASE_URL", "postgresql+psycopg2://demo:demo@postgres:5432/demo"),
    pool_pre_ping=True,
)
Session = sessionmaker(engine, expire_on_commit=False)
