terraform {
  backend "s3" {
    bucket       = "mlops-assignment-terraform-state-543035741305"
    key          = "heart-disease-api/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}
