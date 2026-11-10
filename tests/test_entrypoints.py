from __future__ import annotations

import pytest

from app import __main__ as entrypoint
from app import healthcheck


def test_main_starts_uvicorn_with_settings_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict[str, object] = {}
    monkeypatch.setenv("PORT", "9123")
    monkeypatch.setenv("GRACEFUL_SHUTDOWN_TIMEOUT", "7")
    monkeypatch.setattr(entrypoint.uvicorn, "run", lambda app, **kwargs: captured.update(kwargs))

    entrypoint.main()

    assert captured["port"] == 9123
    assert captured["host"] == "0.0.0.0"  # noqa: S104
    assert captured["timeout_graceful_shutdown"] == 7
    assert captured["log_config"] is None
    assert captured["access_log"] is False


def test_healthcheck_fails_when_nothing_is_listening(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PORT", "1")  # privileged port nothing listens on in tests

    assert healthcheck.main() == 1


def test_healthcheck_succeeds_on_200(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeResponse:
        status = 200

        def __enter__(self) -> FakeResponse:
            return self

        def __exit__(self, *args: object) -> None:
            return None

    monkeypatch.setattr(healthcheck.urllib.request, "urlopen", lambda *a, **k: FakeResponse())

    assert healthcheck.check(8080) is True
