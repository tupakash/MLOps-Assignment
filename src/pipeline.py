from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import mlflow
import mlflow.onnx
import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import (
    ParameterGrid,
    StratifiedKFold,
    cross_validate,
    train_test_split,
)
from sklearn.pipeline import Pipeline
from xgboost import XGBClassifier

from src.data_loader import download_dataset, load_dataset
from src.feature_engineering import build_preprocessor, prepare_features
from src.model_utils import log_model_metrics
from src.onnx_utils import convert_pipeline_to_onnx, save_onnx_model

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATASET_PATH = PROJECT_ROOT / "data" / "heart_disease.csv"
MLFLOW_DB_PATH = PROJECT_ROOT / "notebooks" / "mlflow.db"
MLFLOW_ARTIFACT_DIR = PROJECT_ROOT / "notebooks" / "mlruns"
MODEL_PATH = PROJECT_ROOT / "artifacts" / "heart_disease_model.onnx"
SCORING = {
    "accuracy": "accuracy",
    "precision": "precision",
    "recall": "recall",
    "roc_auc": "roc_auc",
}


def _build_candidate_pipelines(
    X_train: pd.DataFrame,
) -> list[tuple[str, Pipeline, dict[str, object]]]:
    """Build the 20 model and hyperparameter candidates from the training notebook."""
    model_families = [
        (
            "Logistic Regression",
            LogisticRegression(max_iter=1000, random_state=42),
            {"classifier__C": [0.01, 0.1, 1, 10]},
        ),
        (
            "Random Forest",
            RandomForestClassifier(random_state=42),
            {
                "classifier__n_estimators": [100, 200],
                "classifier__max_depth": [None, 8],
                "classifier__min_samples_leaf": [1, 2],
            },
        ),
        (
            "XGBoost",
            XGBClassifier(eval_metric="logloss", random_state=42, n_jobs=1),
            {
                "classifier__n_estimators": [100, 200],
                "classifier__max_depth": [2, 3],
                "classifier__learning_rate": [0.03, 0.1],
            },
        ),
    ]
    candidates = []
    for family, classifier, parameter_grid in model_families:
        for parameters in ParameterGrid(parameter_grid):
            candidate = Pipeline(
                [
                    ("preprocessor", build_preprocessor(X_train)),
                    ("classifier", clone(classifier)),
                ]
            ).set_params(**parameters)
            candidates.append((family, candidate, parameters))
    return candidates


def run_pipeline() -> dict[str, object]:
    """Track 20 candidates and export the CV-selected final model."""
    download_dataset(DATASET_PATH)
    df = load_dataset(DATASET_PATH)
    X, y = prepare_features(df)

    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=0.2,
        random_state=42,
        stratify=y,
    )

    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    candidates = _build_candidate_pipelines(X_train)
    tracking_uri = os.environ.get("MLFLOW_TRACKING_URI")
    if tracking_uri:
        mlflow.set_tracking_uri(tracking_uri)
        experiment = mlflow.set_experiment("heart_disease_assignment")
    else:
        MLFLOW_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        mlflow.set_tracking_uri(f"sqlite:///{MLFLOW_DB_PATH.as_posix()}")
        experiment_name = "heart_disease_assignment"
        if mlflow.get_experiment_by_name(experiment_name) is None:
            mlflow.create_experiment(
                experiment_name,
                artifact_location=MLFLOW_ARTIFACT_DIR.as_uri(),
            )
        experiment = mlflow.set_experiment(experiment_name)
    with mlflow.start_run(run_name="automated_model_selection"):
        mlflow.set_tag("run_source", "automated")
        mlflow.set_tag("mlflow_experiment_id", experiment.experiment_id)
        mlflow.set_tag("workflow", "candidate_comparison")
        mlflow.log_param("candidate_count", len(candidates))
        mlflow.log_param("cv_folds", cv.get_n_splits())
        mlflow.log_param(
            "dataset_sha256",
            hashlib.sha256(DATASET_PATH.read_bytes()).hexdigest(),
        )

        candidate_results = []
        for candidate_number, (family, model, parameters) in enumerate(
            candidates, start=1
        ):
            run_name = (
                f"candidate_{candidate_number:02d}_{family.replace(' ', '_')}"
            )
            with mlflow.start_run(run_name=run_name, nested=True):
                mlflow.set_tag("run_source", "automated")
                mlflow.set_tag("model_family", family)
                mlflow.log_params(parameters)
                cv_results = cross_validate(
                    model,
                    X_train,
                    y_train,
                    cv=cv,
                    scoring=SCORING,
                    n_jobs=1,
                    error_score="raise",
                )
                mean_metrics = {
                    metric: float(np.mean(cv_results[f"test_{metric}"]))
                    for metric in SCORING
                }
                std_metrics = {
                    metric: float(np.std(cv_results[f"test_{metric}"]))
                    for metric in SCORING
                }
                mlflow.log_metrics(
                    {
                        f"cv_{metric}_mean": value
                        for metric, value in mean_metrics.items()
                    }
                )
                mlflow.log_metrics(
                    {
                        f"cv_{metric}_std": value
                        for metric, value in std_metrics.items()
                    }
                )
                candidate_results.append(
                    {
                        "family": family,
                        "model": model,
                        "parameters": parameters,
                        "mean_metrics": mean_metrics,
                    }
                )

        selected_model = max(
            candidate_results,
            key=lambda result: result["mean_metrics"]["roc_auc"],
        )
        selected_estimator = clone(selected_model["model"]).fit(X_train, y_train)
        mlflow.set_tag("selected_model_family", selected_model["family"])
        mlflow.log_param(
            "selected_model_parameters",
            json.dumps(selected_model["parameters"], sort_keys=True),
        )
        mlflow.log_metric(
            "selected_model_cv_roc_auc",
            selected_model["mean_metrics"]["roc_auc"],
        )
        metrics = log_model_metrics(
            selected_estimator,
            X_test,
            y_test,
            model_name="heart_disease_selected_model",
        )
        onnx_model = convert_pipeline_to_onnx(
            selected_estimator,
            list(X_train.columns),
        )
        mlflow.onnx.log_model(onnx_model, name="selected_model")
        save_onnx_model(onnx_model, MODEL_PATH)

        metrics.update(
            {
                "selected_model": selected_model["family"],
                "selected_parameters": selected_model["parameters"],
                "selected_cv_roc_auc": selected_model["mean_metrics"]["roc_auc"],
                "candidate_count": len(candidate_results),
            }
        )
    return metrics


if __name__ == "__main__":
    print(json.dumps(run_pipeline(), indent=2))
