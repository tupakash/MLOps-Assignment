from pathlib import Path

import pandas as pd
import requests

DATASET_URL = (
    "https://archive.ics.uci.edu/ml/machine-learning-databases/heart-disease/processed.cleveland.data"
)


def download_dataset(output_path: str | Path) -> pd.DataFrame:
    """Download the Cleveland Heart Disease dataset if it is not already available."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    if not output_path.exists():
        response = requests.get(DATASET_URL, timeout=30)
        response.raise_for_status()
        output_path.write_bytes(response.content)

    return pd.read_csv(output_path, header=None)


def load_dataset(csv_path: str | Path) -> pd.DataFrame:
    """Load a local CSV dataset and assign useful column names."""
    df = pd.read_csv(csv_path, header=None)

    columns = [
        "age",
        "sex",
        "cp",
        "trestbps",
        "chol",
        "fbs",
        "restecg",
        "thalach",
        "exang",
        "oldpeak",
        "slope",
        "ca",
        "thal",
        "target",
    ]

    if df.shape[1] != len(columns):
        raise ValueError(
            f"Expected {len(columns)} columns but found {df.shape[1]}. "
            "Please confirm the dataset format."
        )

    df.columns = columns
    return df
