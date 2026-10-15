param(
    [string]$Region = "ap-south-1",
    [string]$ProjectName = "heart-disease-api",
    [Parameter(Mandatory = $true)]
    [string]$GitHubRepository,
    [string]$GitHubBranch = "main",
    [string]$ImageTag = "",
    [ValidateSet("t3.micro", "t3.small")]
    [string]$InstanceType = "t3.micro"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path

function Invoke-AwsCli {
    param([string[]]$Arguments)

    $output = & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed: aws $($Arguments -join ' ')"
    }
    return $output
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI is required. Install AWS CLI v2 and configure credentials for $Region."
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker CLI is required. Start Docker Desktop before deploying."
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "Terraform CLI is required. Install Terraform before deploying."
}
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot "artifacts\heart_disease_model.onnx"))) {
    throw "The serving model is missing. Run 'python -m src.pipeline' first."
}

$identity = Invoke-AwsCli -Arguments @(
    "sts", "get-caller-identity",
    "--output", "json",
    "--region", $Region
)
$accountId = ($identity | ConvertFrom-Json).Account

if ([string]::IsNullOrWhiteSpace($ImageTag)) {
    $ImageTag = Get-Date -Format "yyyyMMddHHmmss"
}

$terraformDirectory = $PSScriptRoot
Push-Location $terraformDirectory
try {
    & terraform init
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform initialization failed."
    }

    & terraform apply `
        -auto-approve `
        "-var=aws_region=$Region" `
        "-var=project_name=$ProjectName" `
        "-var=github_repository=$GitHubRepository" `
        "-var=github_deploy_branch=$GitHubBranch" `
        "-var=instance_type=$InstanceType" `
        "-var=image_tag=$ImageTag" `
        -target=aws_ecr_repository.api
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform could not provision the ECR repository."
    }

    $repositoryUri = (& terraform output -raw ecr_repository_url).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repositoryUri)) {
        throw "Terraform did not return the ECR repository URL."
    }

    $imageUri = "${repositoryUri}:${ImageTag}"
    $registry = "${accountId}.dkr.ecr.${Region}.amazonaws.com"
    $password = Invoke-AwsCli -Arguments @(
        "ecr", "get-login-password",
        "--region", $Region
    )
    $password | & docker login --username AWS --password-stdin $registry
    if ($LASTEXITCODE -ne 0) {
        throw "Docker could not authenticate to ECR."
    }

    & docker build --platform linux/amd64 --tag $imageUri $projectRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Docker image build failed."
    }
    & docker push $imageUri
    if ($LASTEXITCODE -ne 0) {
        throw "Pushing the image to ECR failed."
    }

    & terraform apply `
        -auto-approve `
        "-var=aws_region=$Region" `
        "-var=project_name=$ProjectName" `
        "-var=github_repository=$GitHubRepository" `
        "-var=github_deploy_branch=$GitHubBranch" `
        "-var=instance_type=$InstanceType" `
        "-var=image_tag=$ImageTag"
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform could not deploy the ECS service."
    }

    $apiUrl = (& terraform output -raw api_url).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($apiUrl)) {
        throw "Terraform did not return the API URL."
    }

    $githubActionsRoleArn = (& terraform output -raw github_actions_role_arn).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($githubActionsRoleArn)) {
        throw "Terraform did not return the GitHub Actions deployment role ARN."
    }
}
finally {
    Pop-Location
}

Write-Output "API URL: $apiUrl"
Write-Output "GitHub Actions role ARN: $githubActionsRoleArn"
$healthUrl = "$apiUrl/health"
$ready = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 10
        if ($health.status -eq "ok") {
            $ready = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 10
    }
}
if (-not $ready) {
    throw "The API did not become healthy. Inspect ECS service events and CloudWatch logs."
}

$payload = @{
    age = 52
    sex = 1
    cp = 0
    trestbps = 125
    chol = 212
    fbs = 0
    restecg = 1
    thalach = 168
    exang = 0
    oldpeak = 1.0
    slope = 2
    ca = 2
    thal = 3
} | ConvertTo-Json

$prediction = Invoke-RestMethod `
    -Uri "$apiUrl/predict" `
    -Method Post `
    -ContentType "application/json" `
    -Body $payload `
    -TimeoutSec 30

if ($null -eq $prediction.confidence -or $null -eq $prediction.disease_probability) {
    throw "The prediction response did not include confidence values."
}
Write-Output "Prediction smoke test:"
$prediction | ConvertTo-Json
