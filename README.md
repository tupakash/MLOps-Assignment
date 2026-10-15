# Heart Disease Risk Prediction

An end-to-end MLOps project for binary heart disease risk prediction using the
Cleveland Heart Disease dataset from the UCI Machine Learning Repository. The
project brings together exploratory analysis, reproducible model selection,
MLflow experiment tracking, ONNX model export, a containerized prediction API,
automated CI, and an AWS deployment architecture.

This is an academic machine-learning project, not a medical diagnostic tool.

## What the project implements

- **Data exploration and preparation:** Jupyter notebooks document the dataset,
  exploratory data analysis, feature processing, model training, experiment
  tracking, and deployment. The data loader downloads the dataset when the
  local CSV is missing.
- **Reproducible model selection:** `src.pipeline` compares 20 candidates:
  Logistic Regression, Random Forest, and XGBoost configurations. It uses a
  stratified 80/20 train/test split and five-fold stratified cross-validation
  on the training set. Candidate selection is based on mean cross-validation
  ROC-AUC; the selected model is evaluated on the held-out test set.
- **Experiment tracking:** MLflow records candidate parameters and
  cross-validation metrics, the selected model, and held-out test metrics.
  Runs use the `heart_disease_assignment` experiment and, by default, the
  SQLite database at `notebooks/mlflow.db`.
- **Portable model serving:** The selected scikit-learn pipeline is converted
  to ONNX and saved as `artifacts/heart_disease_model.onnx`. The FastAPI
  service runs inference with ONNX Runtime and exposes health and prediction
  endpoints.
- **CI validation:** GitHub Actions installs dependencies, runs Ruff and the
  test suite, executes model selection, then builds the Docker image and
  smoke-tests the API. Training outputs are uploaded as workflow artifacts.
- **AWS infrastructure and monitoring:** Terraform describes a public API
  Gateway protected by AWS WAF, connected through a VPC Link to an internal
  load balancer and private ECS-on-EC2 service. CloudWatch collects structured
  API request logs, and a provisioned Grafana dashboard visualizes request
  volume, errors, latency, and recent events.

## Prediction API

The API accepts the 13 Cleveland dataset features: `age`, `sex`, `cp`,
`trestbps`, `chol`, `fbs`, `restecg`, `thalach`, `exang`, `oldpeak`, `slope`,
`ca`, and `thal`.

- `GET /health` reports service health.
- `POST /predict` returns the predicted class (`0` or `1`), its label
  (`Low risk` or `High risk`), the predicted-class confidence, and the
  probability of the positive/high-risk class.

Each request is logged as a structured JSON event containing the HTTP method,
path, status code, and duration. Request bodies and query strings are not
included in these events.

Example request:

```bash
curl -X POST http://localhost:8000/predict \
  -H "Content-Type: application/json" \
  -d '{"age":52,"sex":1,"cp":0,"trestbps":125,"chol":212,"fbs":0,"restecg":1,"thalach":168,"exang":0,"oldpeak":1.0,"slope":2,"ca":2,"thal":3}'
```

## Project layout

| Path | Purpose |
| --- | --- |
| `notebooks/` | EDA, training, experiment tracking, and deployment notebooks |
| `src/` | Dataset loading, feature engineering, model training, ONNX conversion, and API |
| `tests/` | API and model-pipeline tests |
| `.github/workflows/ci.yml` | Lint, test, train, container build, and API smoke test |
| `deploy/aws/` | Terraform infrastructure, deployment script, and Grafana configuration |
| `requirements.txt` | Training, notebook, tracking, and development dependencies |
| `requirements-serving.txt` | Minimal API runtime dependencies |

Generated model files, MLflow databases and runs, local environment files, and
Terraform state are excluded from Git. Run the training pipeline to generate a
fresh ONNX model before building the serving container.

## Run locally

Install the project dependencies and run the tests:

```bash
python -m pip install -r requirements.txt
python -m pytest -q
ruff check src tests
```

Train, select, track, and export the model:

```bash
python -m src.pipeline
```

Build and run the prediction service with Docker:

```bash
docker build -t heart-disease-api .
docker run --rm -p 8000:8000 heart-disease-api
```

Once running, the API health endpoint is available at
`http://localhost:8000/health`; the interactive API documentation is at
`http://localhost:8000/docs`.

## AWS deployment and monitoring

The Terraform configuration in `deploy/aws/` provisions the deployment
infrastructure in `ap-south-1` by default. The request path is API Gateway and
WAF, then a VPC Link, an internal Application Load Balancer, and ECS running
on a private EC2 instance. The private VPC uses service endpoints for ECS,
ECR, CloudWatch Logs, and S3 rather than a NAT or internet gateway.

`deploy/aws/deploy.ps1` builds a Linux AMD64 container image, pushes it to ECR,
applies the Terraform configuration, and checks the deployed API. It requires
AWS CLI v2, Terraform, Docker Desktop, suitable AWS permissions, and a
generated ONNX model. The Terraform configuration also defines a branch-scoped
GitHub Actions OIDC deployment role; the current CI workflow validates and
smoke-tests the container but does not deploy to AWS.

The Grafana dashboard in `deploy/aws/` queries the CloudWatch API log group for
request volume, HTTP errors, p95 latency, and recent request events. AWS
infrastructure incurs charges while running; review and remove the deployed
resources when they are no longer needed.
