from __future__ import annotations

from pathlib import Path

import onnx
from onnxmltools.convert.common.data_types import (
    FloatTensorType as OnnxToolsFloatTensorType,
)
from onnxmltools.convert.xgboost.operator_converters.XGBoost import convert_xgboost
from onnxmltools.convert.xgboost.shape_calculators.Classifier import (
    calculate_xgboost_classifier_output_shapes,
)
from skl2onnx import convert_sklearn, update_registered_converter
from skl2onnx.common.data_types import FloatTensorType, Int64TensorType
from sklearn.pipeline import Pipeline
from xgboost import XGBClassifier


def convert_pipeline_to_onnx(
    model: Pipeline,
    input_columns: list[str],
) -> onnx.ModelProto:
    """Convert the trained classification pipeline to ONNX for portable inference."""
    classifier = model.named_steps["classifier"]

    if isinstance(classifier, XGBClassifier):

        def calculate_xgboost_shapes(operator) -> None:
            # Bridge the tensor types used by onnxmltools and skl2onnx.
            operator.inputs[0].type = OnnxToolsFloatTensorType(
                shape=operator.inputs[0].type.shape
            )
            calculate_xgboost_classifier_output_shapes(operator)
            operator.outputs[0].type = Int64TensorType(
                shape=operator.outputs[0].type.shape
            )
            operator.outputs[1].type = FloatTensorType(
                shape=operator.outputs[1].type.shape
            )

        update_registered_converter(
            XGBClassifier,
            "XGBoostXGBClassifier",
            calculate_xgboost_shapes,
            convert_xgboost,
            options={"zipmap": [True, False], "nocl": [True, False]},
        )

    return convert_sklearn(
        model,
        initial_types=[
            (column, FloatTensorType([None, 1])) for column in input_columns
        ],
        options={id(classifier): {"zipmap": False}},
        target_opset={"": 17, "ai.onnx.ml": 3},
    )


def save_onnx_model(model: onnx.ModelProto, path: str | Path) -> None:
    """Persist a converted ONNX model."""
    artifact_path = Path(path)
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    onnx.save_model(model, artifact_path)
