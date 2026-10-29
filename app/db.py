"""Shared database definitions used by both the API and the Celery worker.

SQLAlchemy maps Python objects to PostgreSQL rows. A Session groups queries
and writes; db.commit() makes changes durable and visible to other processes.
"""

import os
from datetime import datetime, timezone

from sqlalchemy import JSON, DateTime, String, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker


class Base(DeclarativeBase):
    """Parent for table definitions; its metadata lets startup create the schema."""

    pass


class Job(Base):
    """One prediction request, mapped to one row in prediction_jobs.

    features stores the four input measurements. result stores the prediction
    and model version. result/error are empty until processing produces them.
    Mapped[...] describes a Python attribute; mapped_column defines its SQL column.
    """

    __tablename__ = "prediction_jobs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    status: Mapped[str] = mapped_column(String(20), default="queued")
    features: Mapped[list] = mapped_column(JSON)
    result: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    error: Mapped[str | None] = mapped_column(String(500), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


# Docker/Kubernetes supply DATABASE_URL. The engine manages database connections;
# pool_pre_ping checks a reused connection before handing it to the application.
engine = create_engine(
    os.getenv("DATABASE_URL", "postgresql+psycopg2://demo:demo@postgres:5432/demo"),
    pool_pre_ping=True,
)
# Session() creates a database session. `with Session() as db` closes it after use.
Session = sessionmaker(engine, expire_on_commit=False)
