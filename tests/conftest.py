from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

DEBUG_TOKEN = "test-token"  # noqa: S105 - fixed value for tests only


def make_settings(**overrides: str) -> Settings:
    env = {"APP_VERSION": "1.2.3", "APP_ENV": "test", **overrides}
    return Settings.from_env(env)


@pytest.fixture
def client() -> TestClient:
    with TestClient(create_app(make_settings())) as test_client:
        yield test_client


@pytest.fixture
def debug_client() -> TestClient:
    with TestClient(create_app(make_settings(DEBUG_TOKEN=DEBUG_TOKEN))) as test_client:
        yield test_client
