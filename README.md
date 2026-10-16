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
- **AWS delivery:** After the `MLOps CI` workflow succeeds on `main`, a
  separate GitHub Actions workflow assumes a branch-scoped AWS role with OIDC,
  pushes the serving image to ECR, applies Terraform, and smoke-tests the API.
- **AWS infrastructure and monitoring:** Terraform describes a public API
  Gateway protected by AWS WAF, connected through a VPC Link to an internal
  load balancer and private ECS-on-EC2 service. CloudWatch collects structured
  API request logs, which AWS Managed Grafana visualizes as request volume,
  HTTP errors, latency, and recent events.

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
| `.github/workflows/deploy-aws.yml` | OIDC-authenticated AWS deployment and teardown |
| `deploy/aws/` | Terraform infrastructure, deployment scripts, and Grafana dashboard |
| `deploy/aws/bootstrap/` | Separately managed GitHub OIDC provider and deployment role |
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

## AWS Managed Grafana monitoring

Terraform provisions an AWS Managed Grafana workspace with the CloudWatch
data source. GitHub Actions publishes the CloudWatch Logs dashboard after the
workspace is ready. The dashboard queries the API log group for request rate,
HTTP errors, p95 request latency, and recent request events. It uses the
workspace IAM role to read CloudWatch and does not require Prometheus for this
log-based monitoring setup.

Before the first deployment with Managed Grafana, put the IAM Identity Center
administrator user ID in the ignored
`deploy/aws/bootstrap/terraform.tfvars` file as
`grafana_admin_user_ids = ["<identity-center-user-id>"]`, then apply
`deploy/aws/bootstrap/` with an authorized AWS session. Bootstrap stores this
assignment in account-local Parameter Store and updates the GitHub deployment
role to read only that parameter. The workflow uses it to grant the user
workspace administrator access. It prints the dashboard URL only after it
imports the dashboard and successfully checks CloudWatch Logs query access.

## AWS deployment and monitoring

The Terraform configuration in `deploy/aws/` provisions the deployment
infrastructure in `ap-south-1` by default. The request path is API Gateway and
WAF, then a VPC Link, an internal Application Load Balancer, and ECS running
on a private EC2 instance. The private VPC uses service endpoints for ECS,
ECR, CloudWatch Logs, and S3 rather than a NAT or internet gateway.

`deploy/aws/backend.tf` configures the application stack's encrypted S3 backend
with native S3 lockfiles. `deploy/aws/bootstrap/` manages the GitHub OIDC
provider and deployment role in a separate state key, so application teardown
cannot remove the credentials needed for later deployments. The versioned S3
bucket is bootstrapped once before Terraform initialization; the OIDC role can
access only the application's state object and lockfile. The local deployment
script `deploy/aws/deploy.ps1` remains available for workstation deployments.

The `AWS deployment` workflow runs after successful CI on `main`, or can be
started manually from the Actions tab. Its `destroy` operation removes the
application resources while retaining the separate bootstrap role and shared
state bucket so a later workflow can deploy again. The state bucket and its
versions should be retained to preserve recovery history.

The AWS Managed Grafana workspace and dashboard are provisioned with the
application. AWS resources, including the managed workspace, may incur charges
while running; review and remove deployed resources when they are no longer
needed.
