"""Structured JSON logging to stdout.

One JSON object per line makes logs machine-parseable: Grafana Alloy can extract fields
such as `level` and `path` without fragile regexes, and CloudWatch Logs Insights can query
them directly.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime

from app.config import Settings

# Attributes every LogRecord has. Anything else was passed through `extra=` and is
# emitted as a top-level JSON field.
_STANDARD_ATTRS = frozenset(
    vars(logging.LogRecord("", logging.INFO, "", 0, "", (), None)).keys()
) | {"message", "asctime", "taskName", "color_message"}  # uvicorn adds an ANSI copy


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str, environment: str, version: str) -> None:
        super().__init__()
        self._static = {"service": service, "environment": environment, "version": version}

    def format(self, record: logging.LogRecord) -> str:
        timestamp = datetime.fromtimestamp(record.created, tz=UTC)
        payload: dict[str, object] = {
            "timestamp": timestamp.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "message": record.getMessage(),
            **self._static,
        }
        for key, value in vars(record).items():
            if key not in _STANDARD_ATTRS and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure_logging(settings: Settings) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        JsonFormatter(settings.app_name, settings.environment, settings.app_version)
    )

    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(settings.log_level.upper())

    # Route uvicorn's own logs through the JSON handler. Its access log is replaced by
    # the request-logging middleware, which adds latency and route information.
    for name in ("uvicorn", "uvicorn.error"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers.clear()
        uvicorn_logger.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
