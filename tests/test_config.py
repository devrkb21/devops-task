from __future__ import annotations

import pytest

from app.config import Settings


def test_defaults() -> None:
    settings = Settings.from_env({})

    assert settings.port == 8080
    assert settings.log_level == "info"
    assert settings.environment == "development"
    assert settings.graceful_shutdown_timeout == 20
    assert settings.debug_token is None


def test_reads_values_from_environment() -> None:
    settings = Settings.from_env(
        {
            "PORT": "9000",
            "LOG_LEVEL": "DEBUG",
            "APP_ENV": "staging",
            "APP_VERSION": "2.0.1",
            "GRACEFUL_SHUTDOWN_TIMEOUT": "45",
            "DEBUG_TOKEN": "secret",
        }
    )

    assert settings.port == 9000
    assert settings.log_level == "debug"
    assert settings.environment == "staging"
    assert settings.app_version == "2.0.1"
    assert settings.graceful_shutdown_timeout == 45
    assert settings.debug_token == "secret"  # noqa: S105


def test_empty_debug_token_is_treated_as_unset() -> None:
    assert Settings.from_env({"DEBUG_TOKEN": ""}).debug_token is None


@pytest.mark.parametrize("port", ["abc", "0", "70000"])
def test_invalid_port_fails_fast(port: str) -> None:
    with pytest.raises(ValueError, match="PORT"):
        Settings.from_env({"PORT": port})


def test_invalid_log_level_fails_fast() -> None:
    with pytest.raises(ValueError, match="LOG_LEVEL"):
        Settings.from_env({"LOG_LEVEL": "verbose"})
