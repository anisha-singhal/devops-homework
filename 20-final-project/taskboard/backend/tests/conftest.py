"""Test fixtures.

The suite failed with `no such table: tasks` before this file existed.

Cause: `app/main.py` creates the schema in an `@app.on_event("startup")`
handler, but `tests/test_api.py` builds its client as a module-level
`TestClient(app)`. Starlette only fires startup/shutdown events when the
client is used as a context manager, so the handler never ran and the first
test that touched the database failed.

Two ways to fix it: wrap every test in `with TestClient(app) as client:`, or
create the schema once in a session fixture. The fixture is used here because
it leaves the existing tests unchanged and makes the dependency explicit.
"""
import os

os.environ.setdefault("DATABASE_URL", "sqlite:///./test.db")

import pytest

from app.db import Base, engine


@pytest.fixture(scope="session", autouse=True)
def create_schema():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)
