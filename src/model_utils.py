from __future__ import annotations

from pathlib import Path

import joblib
import mlflow
import pandas as pd
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    precision_score,
    recall_score,
    roc_auc_score,
)


def log_model_metrics(model, X_test: pd.DataFrame, y_test: pd.Series, model_name: str = "heart_disease_model") -> dict:
    """Evaluate a trained model and log metrics to MLflow."""
    predictions = model.predict(X_test)
    probabilities = model.predict_proba(X_test)[:, 1]
    acc = accuracy_score(y_test, predictions)
    precision = precision_score(y_test, predictions, zero_division=0)
    recall = recall_score(y_test, predictions, zero_division=0)
    roc_auc = roc_auc_score(y_test, probabilities)
    cm = confusion_matrix(y_test, predictions)

    mlflow.log_metric("accuracy", acc)
    mlflow.log_metric("precision", precision)
    mlflow.log_metric("recall", recall)
    mlflow.log_metric("roc_auc", roc_auc)
    mlflow.log_metric("tn", cm[0, 0])
    mlflow.log_metric("fp", cm[0, 1])
    mlflow.log_metric("fn", cm[1, 0])
    mlflow.log_metric("tp", cm[1, 1])

    report = classification_report(y_test, predictions, output_dict=True)
    mlflow.log_dict(report, f"{model_name}_classification_report.json")

    return {
        "accuracy": acc,
        "precision": precision,
        "recall": recall,
        "roc_auc": roc_auc,
        "confusion_matrix": cm.tolist(),
    }


def save_model(model, path: str | Path) -> None:
    """Persist the model artifact to disk."""
    artifact_path = Path(path)
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, artifact_path)


def load_model(path: str | Path):
    """Load a saved model artifact."""
    return joblib.load(path)
