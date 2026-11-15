"""Small shared helpers for the GraceCare portfolio scripts (Parts 2-4).

Connection settings come from environment variables set in docker-compose.yml, so the
same scripts work inside the `tools` container or on a laptop with a local database.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

import psycopg

PG_DSN = os.environ.get(
    "PG_DSN", "host=localhost port=15432 dbname=gracecare user=gc password=gc_local_only"
)
MONGO_URI = os.environ.get("MONGO_URI", "mongodb://localhost:27017/?replicaSet=rs0")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")


def pg_connect(autocommit: bool = False, isolation: str | None = None,
               app_name: str = "gracecare-portfolio") -> psycopg.Connection:
    """Open a PostgreSQL connection with search_path set to the gc schema."""
    conn = psycopg.connect(PG_DSN, autocommit=autocommit, application_name=app_name,
                           options="-c search_path=gc,public")
    if isolation:
        conn.isolation_level = getattr(psycopg.IsolationLevel, isolation.replace(" ", "_").upper())
    return conn


class Report:
    """Prints to the console and writes the same text to a results file."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lines: list[str] = []
        self._t0 = time.perf_counter()

    def __call__(self, text: str = "") -> None:
        print(text)
        sys.stdout.flush()
        self._lines.append(text)

    def heading(self, text: str) -> None:
        self("")
        self("=" * 88)
        self(text)
        self("=" * 88)

    def elapsed_ms(self) -> float:
        return (time.perf_counter() - self._t0) * 1000

    def save(self) -> None:
        self.path.write_text("\n".join(self._lines) + "\n", encoding="utf-8")
        print(f"\n[saved] {self.path}")
