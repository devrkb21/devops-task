from __future__ import annotations

from fastapi.testclient import TestClient
from prometheus_client import REGISTRY

from app.main import create_app
from tests.conftest import DEBUG_TOKEN, make_settings


def sample(name: str, **labels: str) -> float:
    return REGISTRY.get_sample_value(name, labels) or 0.0


def test_root_returns_expected_payload(client: TestClient) -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.json() == {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": "1.2.3",
    }


def test_health_returns_ok(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_metrics_exposes_prometheus_format(client: TestClient) -> None:
    client.get("/")

    response = client.get("/metrics")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    body = response.text
    assert 'http_requests_total{method="GET",path="/",status="200"}' in body
    assert "http_request_duration_seconds_bucket" in body
    assert "http_request_errors_total" in body
    assert 'app_build_info{environment="test",version="1.2.3"} 1.0' in body


def test_request_counter_and_latency_histogram_increase(client: TestClient) -> None:
    requests_before = sample("http_requests_total", method="GET", path="/", status="200")
    latency_before = sample("http_request_duration_seconds_count", method="GET", path="/")

    client.get("/")
    client.get("/")

    assert sample("http_requests_total", method="GET", path="/", status="200") == (
        requests_before + 2
    )
    assert sample("http_request_duration_seconds_count", method="GET", path="/") == (
        latency_before + 2
    )


def test_unknown_paths_share_one_label_value(client: TestClient) -> None:
    before = sample("http_requests_total", method="GET", path="unmatched", status="404")

    assert client.get("/does-not-exist").status_code == 404
    assert client.get("/another/random/path").status_code == 404

    assert sample("http_requests_total", method="GET", path="unmatched", status="404") == (
        before + 2
    )


def test_client_errors_are_not_counted_as_errors(client: TestClient) -> None:
    before = sample("http_request_errors_total", method="GET", path="unmatched")

    client.get("/does-not-exist")

    assert sample("http_request_errors_total", method="GET", path="unmatched") == before


def test_server_error_increments_error_counter(debug_client: TestClient) -> None:
    before = sample("http_request_errors_total", method="GET", path="/debug/error")

    response = debug_client.get("/debug/error", headers={"X-Debug-Token": DEBUG_TOKEN})

    assert response.status_code == 500
    assert response.json() == {"detail": "Internal Server Error"}  # no stack trace leaked
    assert sample("http_request_errors_total", method="GET", path="/debug/error") == before + 1


def test_debug_slow_sleeps_and_is_capped(debug_client: TestClient) -> None:
    headers = {"X-Debug-Token": DEBUG_TOKEN}

    assert debug_client.get("/debug/slow?ms=10", headers=headers).json() == {"slept_ms": 10}
    assert debug_client.get("/debug/slow?ms=999999", headers=headers).status_code == 422


def test_debug_endpoints_reject_missing_or_wrong_token(debug_client: TestClient) -> None:
    assert debug_client.get("/debug/error").status_code == 403
    assert debug_client.get("/debug/error", headers={"X-Debug-Token": "nope"}).status_code == 403


def test_debug_endpoints_do_not_exist_without_token(client: TestClient) -> None:
    assert client.get("/debug/error").status_code == 404
    assert client.get("/debug/slow").status_code == 404


def test_api_docs_are_disabled_in_production() -> None:
    with TestClient(create_app(make_settings(APP_ENV="production"))) as prod_client:
        assert prod_client.get("/docs").status_code == 404
        assert prod_client.get("/openapi.json").status_code == 404
