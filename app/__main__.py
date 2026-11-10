"""Entry point: `python -m app`."""

from __future__ import annotations

import uvicorn

from app.config import Settings
from app.logging_config import configure_logging
from app.main import create_app


def main() -> None:
    settings = Settings.from_env()
    configure_logging(settings)
    uvicorn.run(
        create_app(settings),
        host=settings.host,
        port=settings.port,
        # Logging is configured above; stop uvicorn from installing its own text handlers.
        log_config=None,
        access_log=False,
        server_header=False,
        # On SIGTERM uvicorn stops accepting connections, then waits up to this long for
        # in-flight requests before exiting.
        timeout_graceful_shutdown=settings.graceful_shutdown_timeout,
    )


if __name__ == "__main__":
    main()
