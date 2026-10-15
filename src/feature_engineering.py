from __future__ import annotations

import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.impute import SimpleImputer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

NUMERIC_FEATURES = ["age", "trestbps", "chol", "thalach", "oldpeak", "ca"]
CATEGORICAL_FEATURES = [
    "sex",
    "cp",
    "fbs",
    "restecg",
    "exang",
    "slope",
    "thal",
]


def prepare_features(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.Series]:
    """Convert the Cleveland data to numeric features and a binary target."""
    if "target" not in df.columns:
        raise ValueError("The dataset must contain a 'target' column.")

    cleaned = df.replace(r"^\s*\?\s*$", pd.NA, regex=True).copy()
    for column in cleaned.columns:
        converted = pd.to_numeric(cleaned[column], errors="coerce")
        invalid = cleaned[column].notna() & converted.isna()
        if invalid.any():
            examples = cleaned.loc[invalid, column].astype(str).unique()[:5].tolist()
            raise ValueError(
                f"Column '{column}' contains values that are not numeric: {examples}"
            )
        cleaned[column] = converted

    if cleaned["target"].isna().any():
        raise ValueError("The target column cannot contain missing values.")

    target_values = set(cleaned["target"].unique())
    if not target_values.issubset({0, 1, 2, 3, 4}):
        raise ValueError(f"Unexpected target values: {sorted(target_values)}")

    X = cleaned.drop(columns=["target"])
    y = (cleaned["target"] > 0).astype(int)
    return X, y


def build_preprocessor(X: pd.DataFrame) -> Pipeline:
    """Create an imputation, scaling, and encoding pipeline for Cleveland data."""
    expected_features = set(NUMERIC_FEATURES + CATEGORICAL_FEATURES)
    actual_features = set(X.columns)
    missing_features = expected_features - actual_features
    unexpected_features = actual_features - expected_features

    if missing_features or unexpected_features:
        raise ValueError(
            "Unexpected feature columns. "
            f"Missing: {sorted(missing_features)}; "
            f"unexpected: {sorted(unexpected_features)}"
        )

    transformer = ColumnTransformer(
        transformers=[
            (
                "num",
                Pipeline(
                    [
                        ("imputer", SimpleImputer(strategy="median")),
                        ("scaler", StandardScaler()),
                    ]
                ),
                NUMERIC_FEATURES,
            ),
            (
                "cat",
                Pipeline(
                    [
                        ("imputer", SimpleImputer(strategy="most_frequent")),
                        ("encoder", OneHotEncoder(handle_unknown="ignore")),
                    ]
                ),
                CATEGORICAL_FEATURES,
            ),
        ],
        remainder="drop",
    )

    return Pipeline([("preprocessor", transformer)])
