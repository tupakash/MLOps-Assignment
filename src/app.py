from __future__ import annotations

import json
import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager
from pathlib import Path
from time import perf_counter

import numpy as np
import onnxruntime as ort
from fastapi import FastAPI, Request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel
from starlette.responses import Response

PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODEL_PATH = PROJECT_ROOT / "artifacts" / "heart_disease_model.onnx"

request_logger = logging.getLogger("api.requests")
model_session: ort.InferenceSession | None = None
metrics_registry = CollectorRegistry()
http_requests_total = Counter(
    "http_requests_total",
    "Total number of HTTP requests.",
    ("method", "path", "status_code"),
    registry=metrics_registry,
)
http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds.",
    ("method", "path"),
    registry=metrics_registry,
)
METRIC_PATHS = frozenset({"/health", "/predict", "/metrics"})


class PatientRecord(BaseModel):
    age: float
    sex: float
    cp: float
    trestbps: float
    chol: float
    fbs: float
    restecg: float
    thalach: float
    exang: float
    oldpeak: float
    slope: float
    ca: float
    thal: float


def load_model() -> None:
    global model_session
    model_session = ort.InferenceSession(
        str(MODEL_PATH),
        providers=["CPUExecutionProvider"],
    )


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncGenerator[None, None]:
    load_model()
    yield


app = FastAPI(title="Heart Disease Prediction API", lifespan=lifespan)


@app.middleware("http")
async def log_api_request(request: Request, call_next):
    started_at = perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        duration_seconds = perf_counter() - started_at
        if request.url.path != "/metrics":
            metric_path = (
                request.url.path
                if request.url.path in METRIC_PATHS
                else "unmatched"
            )
            http_requests_total.labels(
                method=request.method,
                path=metric_path,
                status_code=str(status_code),
            ).inc()
            http_request_duration_seconds.labels(
                method=request.method,
                path=metric_path,
            ).observe(duration_seconds)
        request_logger.info(
            json.dumps(
                {
                    "event": "api_request",
                    "method": request.method,
                    "path": request.url.path,
                    "status_code": status_code,
                    "duration_ms": round(duration_seconds * 1000, 3),
                },
                separators=(",", ":"),
            )
        )


@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    return Response(
        generate_latest(metrics_registry),
        headers={"Content-Type": CONTENT_TYPE_LATEST},
    )


@app.get("/health")
def health_check() -> dict:
    return {"status": "ok"}


@app.post("/predict")
def predict(record: PatientRecord) -> dict:
    if model_session is None:
        raise RuntimeError("The ONNX model has not been loaded.")

    record_values = record.model_dump()
    model_inputs = {
        feature_name: np.asarray([[value]], dtype=np.float32)
        for feature_name, value in record_values.items()
    }
    prediction_output, probability_output = model_session.run(None, model_inputs)
    prediction = int(np.asarray(prediction_output).reshape(-1)[0])
    probabilities = np.asarray(probability_output, dtype=np.float64)
    if probabilities.shape != (1, 2):
        raise RuntimeError(
            f"Expected binary-class probabilities with shape (1, 2), "
            f"received {probabilities.shape}."
        )

    disease_probability = float(probabilities[0, 1])
    confidence = float(probabilities[0, prediction])
    return {
        "prediction": prediction,
        "label": "High risk" if prediction == 1 else "Low risk",
        "confidence": confidence,
        "disease_probability": disease_probability,
    }
