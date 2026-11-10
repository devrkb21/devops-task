"""Application settings.

Every setting comes from an environment variable so the same image runs unchanged in
local Docker, on EC2 and in Kubernetes (12-factor style). Invalid values fail fast at
startup instead of causing confusing behaviour later.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

VALID_LOG_LEVELS = ("debug", "info", "warning", "error", "critical")


def _int_env(env: Mapping[str, str], name: str, default: int, minimum: int, maximum: int) -> int:
    raw = env.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}, got {value}")
    return value


@dataclass(frozen=True)
class Settings:
    app_name: str
    app_version: str
    environment: str
    host: str
    port: int
    log_level: str
    graceful_shutdown_timeout: int
    debug_token: str | None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        env = os.environ if env is None else env

        log_level = env.get("LOG_LEVEL", "info").strip().lower()
        if log_level not in VALID_LOG_LEVELS:
            raise ValueError(f"LOG_LEVEL must be one of {VALID_LOG_LEVELS}, got {log_level!r}")

        return cls(
            app_name=env.get("APP_NAME", "devops-task"),
            app_version=env.get("APP_VERSION", "0.0.0-dev"),
            environment=env.get("APP_ENV", "development"),
            # Inside a container the app must listen on all interfaces to be reachable.
            host=env.get("HOST", "0.0.0.0"),  # noqa: S104
            port=_int_env(env, "PORT", 8080, 1, 65535),
            log_level=log_level,
            graceful_shutdown_timeout=_int_env(env, "GRACEFUL_SHUTDOWN_TIMEOUT", 20, 1, 300),
            # Optional. When set, the /debug/* endpoints are enabled and require this token.
            debug_token=env.get("DEBUG_TOKEN") or None,
        )
