from __future__ import annotations

import json
import logging
import sys

import pytest
from fastapi.testclient import TestClient

from app.logging_config import JsonFormatter, configure_logging
from app.main import create_app
from tests.conftest import make_settings


def make_record(**extra: object) -> logging.LogRecord:
    record = logging.LogRecord(
        "app.access", logging.INFO, __file__, 1, "request %s", ("done",), None
    )
    for key, value in extra.items():
        setattr(record, key, value)
    return record


def test_formatter_emits_one_json_object_with_extras() -> None:
    formatter = JsonFormatter(service="svc", environment="test", version="1.0.0")

    line = formatter.format(make_record(path="/", status=200))
    payload = json.loads(line)

    assert "\n" not in line
    assert payload["level"] == "info"
    assert payload["message"] == "request done"
    assert payload["logger"] == "app.access"
    assert payload["service"] == "svc"
    assert payload["environment"] == "test"
    assert payload["version"] == "1.0.0"
    assert payload["path"] == "/"
    assert payload["status"] == 200
    assert payload["timestamp"].endswith("Z")


def test_formatter_includes_exception_text() -> None:
    formatter = JsonFormatter(service="svc", environment="test", version="1.0.0")
    try:
        raise ValueError("boom")
    except ValueError:
        record = logging.LogRecord("app", logging.ERROR, __file__, 1, "failed", (), sys.exc_info())

    payload = json.loads(formatter.format(record))

    assert "ValueError: boom" in payload["exception"]


def test_access_log_is_json_on_stdout(capsys: pytest.CaptureFixture[str]) -> None:
    settings = make_settings(LOG_LEVEL="info")
    configure_logging(settings)

    with TestClient(create_app(settings)) as client:
        client.get("/")
        client.get("/health")  # logged at DEBUG, so hidden at INFO

    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines() if line]
    access = [line for line in lines if line["logger"] == "app.access"]

    assert [entry["path"] for entry in access] == ["/"]
    assert access[0]["status"] == 200
    assert access[0]["route"] == "/"
    assert "duration_ms" in access[0]
    assert any(line["message"] == "application started" for line in lines)
    assert any(line["message"] == "application shutdown complete" for line in lines)
