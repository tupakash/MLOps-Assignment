# Dataset folder

This folder is used to store the Cleveland heart disease dataset used in the MLOps assignment.

Expected file:
- `heart_disease.csv`

The notebooks and training pipelines download the dataset from the UCI Machine Learning Repository with
`src.data_loader.download_dataset` when this file is missing, then load it with `load_dataset`.
