from pathlib import Path

import numpy as np
import onnxruntime as ort
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from xgboost import XGBClassifier

from src.data_loader import load_dataset
from src.feature_engineering import (
    CATEGORICAL_FEATURES,
    NUMERIC_FEATURES,
    build_preprocessor,
    prepare_features,
)
from src.onnx_utils import convert_pipeline_to_onnx
from src.pipeline import _build_candidate_pipelines

DATASET_PATH = Path("data/heart_disease.csv")


def test_candidate_pipeline_grid_matches_training_notebook():
    feature_columns = NUMERIC_FEATURES + CATEGORICAL_FEATURES
    candidates = _build_candidate_pipelines(pd.DataFrame(columns=feature_columns))
    family_counts = pd.Series([family for family, _, _ in candidates]).value_counts()

    assert len(candidates) == 20
    assert family_counts.to_dict() == {
        "Random Forest": 8,
        "XGBoost": 8,
        "Logistic Regression": 4,
    }


def test_dataset_has_expected_columns():
    if not DATASET_PATH.exists():
        return

    df = load_dataset(DATASET_PATH)
    assert "target" in df.columns
    assert df.shape[1] >= 14


def test_feature_split_is_valid():
    sample = pd.DataFrame(
        {
            "age": [52, 48],
            "sex": [1, 0],
            "cp": [3, 2],
            "trestbps": [130, 120],
            "chol": [220, 200],
            "fbs": [0, 1],
            "restecg": [0, 1],
            "thalach": [150, 160],
            "exang": [0, 1],
            "oldpeak": [2.3, 1.0],
            "slope": [2, 1],
            "ca": [1, 0],
            "thal": [3, 2],
            "target": [1, 0],
        }
    )

    X, y = prepare_features(sample)
    assert X.shape[1] == 13
    assert y.shape[0] == 2
    assert set(y.unique()).issubset({0, 1})
    assert "ca" in NUMERIC_FEATURES
    assert "ca" not in CATEGORICAL_FEATURES


def test_prepare_features_converts_missing_markers_and_binarizes_target():
    sample = pd.DataFrame(
        {
            "age": [52, 48, 61, 55],
            "sex": [1, 0, 1, 0],
            "cp": [3, 2, 4, 1],
            "trestbps": [130, 120, 140, 125],
            "chol": [220, 200, 240, 210],
            "fbs": [0, 1, 0, 0],
            "restecg": [0, 1, 2, 0],
            "thalach": [150, 160, 130, 170],
            "exang": [0, 1, 1, 0],
            "oldpeak": [2.3, 1.0, 3.1, 0.5],
            "slope": [2, 1, 3, 2],
            "ca": ["1", "?", "2", "0"],
            "thal": ["3", "6", "?", "7"],
            "target": [0, 1, 2, 4],
        }
    )

    X, y = prepare_features(sample)

    assert y.tolist() == [0, 1, 1, 1]
    assert pd.isna(X.loc[1, "ca"])
    assert pd.isna(X.loc[2, "thal"])


def test_full_model_pipeline_imputes_and_predicts_from_raw_features():
    sample = pd.DataFrame(
        {
            "age": [52, 48, 61, 55],
            "sex": [1, 0, 1, 0],
            "cp": [3, 2, 4, 1],
            "trestbps": [130, 120, 140, 125],
            "chol": [220, 200, 240, 210],
            "fbs": [0, 1, 0, 0],
            "restecg": [0, 1, 2, 0],
            "thalach": [150, 160, 130, 170],
            "exang": [0, 1, 1, 0],
            "oldpeak": [2.3, 1.0, 3.1, 0.5],
            "slope": [2, 1, 3, 2],
            "ca": [1, float("nan"), 2, 0],
            "thal": [3, 6, float("nan"), 7],
        }
    )
    target = pd.Series([0, 0, 1, 1])
    model = Pipeline(
        [
            ("preprocessor", build_preprocessor(sample)),
            ("classifier", LogisticRegression()),
        ]
    )

    model.fit(sample, target)

    assert model.predict(sample).shape == (4,)


def test_onnx_export_matches_predictions_for_each_classifier_family():
    sample = pd.DataFrame(
        {
            "age": [52, 48, 61, 55, 45, 63],
            "sex": [1, 0, 1, 0, 1, 0],
            "cp": [3, 2, 4, 1, 2, 3],
            "trestbps": [130, 120, 140, 125, 118, 145],
            "chol": [220, 200, 240, 210, 195, 255],
            "fbs": [0, 1, 0, 0, 0, 1],
            "restecg": [0, 1, 2, 0, 1, 2],
            "thalach": [150, 160, 130, 170, 165, 125],
            "exang": [0, 1, 1, 0, 0, 1],
            "oldpeak": [2.3, 1.0, 3.1, 0.5, 0.8, 2.7],
            "slope": [2, 1, 3, 2, 1, 3],
            "ca": [1, float("nan"), 2, 0, 1, 3],
            "thal": [3, 6, float("nan"), 7, 3, 6],
        }
    )
    target = pd.Series([0, 0, 1, 1, 0, 1])
    classifiers = [
        LogisticRegression(max_iter=1000, random_state=42),
        RandomForestClassifier(n_estimators=5, random_state=42),
        XGBClassifier(
            n_estimators=5,
            max_depth=2,
            eval_metric="logloss",
            random_state=42,
            n_jobs=1,
        ),
    ]

    for classifier in classifiers:
        model = Pipeline(
            [
                ("preprocessor", build_preprocessor(sample)),
                ("classifier", classifier),
            ]
        )
        model.fit(sample, target)
        onnx_model = convert_pipeline_to_onnx(model, list(sample.columns))
        session = ort.InferenceSession(
            onnx_model.SerializeToString(),
            providers=["CPUExecutionProvider"],
        )
        model_inputs = {
            feature: sample[[feature]].to_numpy(dtype=np.float32)
            for feature in sample.columns
        }
        onnx_predictions = session.run(None, model_inputs)[0]

        np.testing.assert_array_equal(model.predict(sample), onnx_predictions)
