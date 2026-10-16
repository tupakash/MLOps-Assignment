import asyncio
import json

import numpy as np
import pytest
from starlette.requests import Request
from starlette.responses import Response

from src import app as app_module


class StubInferenceSession:
    def __init__(self, model_path, providers):
        self.model_path = model_path
        self.providers = providers

    def run(self, output_names, model_inputs):
        return np.asarray([1]), np.asarray([[0.2, 0.8]], dtype=np.float32)


def test_predict_returns_prediction_label_and_confidence(monkeypatch):
    monkeypatch.setattr(
        app_module.ort,
        "InferenceSession",
        StubInferenceSession,
    )
    app_module.load_model()
    record = app_module.PatientRecord(
        age=52,
        sex=1,
        cp=0,
        trestbps=125,
        chol=212,
        fbs=0,
        restecg=1,
        thalach=168,
        exang=0,
        oldpeak=1.0,
        slope=2,
        ca=2,
        thal=3,
    )

    response = app_module.predict(record)

    assert response["prediction"] == 1
    assert response["label"] == "High risk"
    assert response["confidence"] == pytest.approx(0.8)
    assert response["disease_probability"] == pytest.approx(0.8)


def test_health_endpoint_returns_ok(monkeypatch):
    monkeypatch.setattr(
        app_module.ort,
        "InferenceSession",
        StubInferenceSession,
    )
    app_module.load_model()
    assert app_module.health_check() == {"status": "ok"}


def test_api_requests_are_logged_as_structured_events(caplog):
    scope = {
        "type": "http",
        "asgi": {"version": "3.0"},
        "http_version": "1.1",
        "method": "GET",
        "scheme": "http",
        "path": "/health",
        "raw_path": b"/health",
        "query_string": b"ignored=value",
        "root_path": "",
        "headers": [],
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }
    request = Request(scope)

    async def call_next(_request):
        return Response(status_code=200)

    with caplog.at_level("INFO", logger="api.requests"):
        response = asyncio.run(app_module.log_api_request(request, call_next))

    assert response.status_code == 200
    request_events = [
        json.loads(record.message)
        for record in caplog.records
        if record.name == "api.requests"
    ]
    assert len(request_events) == 1
    assert request_events[0]["event"] == "api_request"
    assert request_events[0]["method"] == "GET"
    assert request_events[0]["path"] == "/health"
    assert request_events[0]["status_code"] == 200
    assert request_events[0]["duration_ms"] >= 0

    metrics = app_module.metrics()
    metrics_text = metrics.body.decode()
    assert '# TYPE http_requests_total counter' in metrics_text
    assert '{method="GET",path="/health",status_code="200"}' in metrics_text
    assert '# TYPE http_request_duration_seconds histogram' in metrics_text
