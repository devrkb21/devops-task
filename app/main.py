"""HTTP application: routes, request instrumentation and lifecycle hooks."""

from __future__ import annotations

import asyncio
import hmac
import logging
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager

from fastapi import FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app import metrics
from app.config import Settings

logger = logging.getLogger("app")
access_logger = logging.getLogger("app.access")

# Probe and scrape traffic is constant and uninteresting, so it is logged at DEBUG.
# At the default INFO level it would otherwise drown out real requests.
QUIET_PATHS = frozenset({"/health", "/metrics"})


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", None) or metrics.UNMATCHED_PATH


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        metrics.BUILD_INFO.labels(settings.app_version, settings.environment).set(1)
        logger.info(
            "application started",
            extra={"port": settings.port, "debug_endpoints": bool(settings.debug_token)},
        )
        yield
        # Uvicorn calls this after SIGTERM, once it has stopped accepting new connections
        # and in-flight requests have finished (or the graceful timeout expired).
        logger.info("application shutdown complete")

    production = settings.environment == "production"
    app = FastAPI(
        title=settings.app_name,
        version=settings.app_version,
        lifespan=lifespan,
        # Interactive API docs are handy locally but are unnecessary surface in production.
        docs_url=None if production else "/docs",
        redoc_url=None,
        openapi_url=None if production else "/openapi.json",
    )

    @app.middleware("http")
    async def instrument_requests(
        request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        start = time.perf_counter()
        metrics.IN_PROGRESS.inc()
        status = 500
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        except Exception:
            # Log once, with request context, and return a generic body so stack traces
            # never reach the client.
            logger.exception(
                "unhandled exception",
                extra={"method": request.method, "path": request.url.path},
            )
            return JSONResponse({"detail": "Internal Server Error"}, status_code=500)
        finally:
            duration = time.perf_counter() - start
            metrics.IN_PROGRESS.dec()
            route = _route_template(request)
            method = request.method
            metrics.REQUESTS.labels(method, route, str(status)).inc()
            metrics.LATENCY.labels(method, route).observe(duration)
            if status >= 500:
                metrics.ERRORS.labels(method, route).inc()

            if status >= 500:
                level = logging.ERROR
            elif status >= 400:
                level = logging.WARNING
            elif route in QUIET_PATHS:
                level = logging.DEBUG
            else:
                level = logging.INFO
            access_logger.log(
                level,
                "request completed",
                extra={
                    "method": method,
                    "path": request.url.path,
                    "route": route,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client_ip": request.client.host if request.client else None,
                },
            )

    @app.get("/")
    async def root() -> dict[str, str]:
        return {
            "message": "Hello from DevOps Task!",
            "status": "running",
            "version": settings.app_version,
        }

    @app.get("/health")
    async def health() -> dict[str, str]:
        # Liveness and readiness: the process is up and its event loop is serving requests.
        # The service has no downstream dependencies (database, cache) to check.
        return {"status": "ok"}

    @app.get("/metrics", include_in_schema=False)
    async def prometheus_metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    if settings.debug_token:
        _register_debug_routes(app, settings.debug_token)

    return app


def _register_debug_routes(app: FastAPI, token: str) -> None:
    """Endpoints that simulate failures, used to demo dashboards and alerts.

    They only exist when DEBUG_TOKEN is set, and every call must present that token.
    """

    def require_token(supplied: str | None) -> None:
        if supplied is None or not hmac.compare_digest(supplied, token):
            raise HTTPException(status_code=403, detail="invalid debug token")

    @app.get("/debug/error", include_in_schema=False)
    async def debug_error(x_debug_token: str | None = Header(default=None)) -> None:
        require_token(x_debug_token)
        raise RuntimeError("simulated failure triggered via /debug/error")

    @app.get("/debug/slow", include_in_schema=False)
    async def debug_slow(
        ms: int = Query(default=1000, ge=0, le=5000),
        x_debug_token: str | None = Header(default=None),
    ) -> dict[str, int]:
        require_token(x_debug_token)
        await asyncio.sleep(ms / 1000)
        return {"slept_ms": ms}
