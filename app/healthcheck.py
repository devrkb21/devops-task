"""Container health check: `python -m app.healthcheck`.

Used by the Dockerfile HEALTHCHECK and docker-compose. It needs no curl or wget, so the
runtime image can stay minimal.
"""

from __future__ import annotations

import os
import sys
import urllib.error
import urllib.request


def check(port: int, timeout: float = 2.0) -> bool:
    url = f"http://127.0.0.1:{port}/health"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:  # noqa: S310
            return response.status == 200
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return False


def main() -> int:
    port = int(os.environ.get("PORT", "8080"))
    return 0 if check(port) else 1


if __name__ == "__main__":
    sys.exit(main())
