"""Prometheus metrics.

Label values are kept to a small, fixed set: `path` is the route template (for example
"/" or "/health"), never the raw URL, and unknown URLs are grouped under "unmatched".
Otherwise a scanner hitting random URLs would create a new time series per URL.
"""

from __future__ import annotations

from prometheus_client import Counter, Gauge, Histogram

UNMATCHED_PATH = "unmatched"

REQUESTS = Counter(
    "http_requests_total",
    "Total HTTP requests handled.",
    ["method", "path", "status"],
)

ERRORS = Counter(
    "http_request_errors_total",
    "HTTP requests that ended in a 5xx response or an unhandled exception.",
    ["method", "path"],
)

LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds.",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being processed.",
)

BUILD_INFO = Gauge(
    "app_build_info",
    "Always 1. Labels carry the running version and environment.",
    ["version", "environment"],
)
