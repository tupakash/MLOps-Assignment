terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.25, < 7.0"
    }
  }

  backend "s3" {
    bucket       = "mlops-assignment-terraform-state-543035741305"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

variable "aws_region" {
  description = "AWS region for the deployment."
  type        = string
  default     = "ap-south-1"
}

variable "grafana_region" {
  description = "AWS region for the Managed Grafana workspace."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix used to name AWS resources."
  type        = string
  default     = "heart-disease-api"
}

provider "aws" {
  region = var.aws_region
}

variable "github_repository" {
  description = "GitHub owner/repository allowed to assume the deployment role."
  type        = string
  default     = "tupakash/MLOps-Assignment"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use the owner/repository format."
  }
}

variable "github_repository_owner_id" {
  description = "Immutable GitHub owner ID included in the OIDC subject claim."
  type        = string
  default     = "190912519"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_owner_id))
    error_message = "github_repository_owner_id must be a numeric GitHub ID."
  }
}

variable "github_repository_id" {
  description = "Immutable GitHub repository ID included in the OIDC subject claim."
  type        = string
  default     = "1420296006"

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be a numeric GitHub ID."
  }
}

variable "github_deploy_branch" {
  description = "Branch whose GitHub Actions workflows may deploy the AWS stack."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.github_deploy_branch))
    error_message = "github_deploy_branch must be a valid simple branch name."
  }
}

variable "terraform_state_bucket" {
  description = "S3 bucket containing the shared Terraform state."
  type        = string
  default     = "mlops-assignment-terraform-state-543035741305"
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs to grant AWS Managed Grafana administrator access."
  type        = list(string)
}

data "aws_caller_identity" "current" {}

locals {
  ecs_runtime_boundary_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-ecs-runtime-boundary"
  github_repository_owner   = split("/", var.github_repository)[0]
  github_repository_name    = split("/", var.github_repository)[1]
  github_repository_subject = "${local.github_repository_owner}@${var.github_repository_owner_id}/${local.github_repository_name}@${var.github_repository_id}"
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_ssm_parameter" "grafana_admin_user_ids" {
  name  = "/${var.project_name}/grafana/admin-user-ids"
  type  = "String"
  value = jsonencode(var.grafana_admin_user_ids)

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name                 = "${var.project_name}-github-actions-deploy"
  description          = "GitHub Actions role for Terraform deployment of the ${var.project_name} stack."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repository_subject}:ref:refs/heads/${var.github_deploy_branch}"
        }
      }
    }]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_policy" "github_actions_deploy" {
  name        = "${var.project_name}-github-actions-deploy"
  description = "Permissions for GitHub Actions to apply this project's AWS infrastructure."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageProjectEcrRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:CreateRepository",
          "ecr:DeleteRepository",
          "ecr:DeleteRepositoryPolicy",
          "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer",
          "ecr:GetRepositoryPolicy",
          "ecr:InitiateLayerUpload",
          "ecr:ListImages",
          "ecr:ListTagsForResource",
          "ecr:PutImage",
          "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability",
          "ecr:SetRepositoryPolicy",
          "ecr:TagResource",
          "ecr:UntagResource",
          "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}"
      },
      {
        Sid      = "AuthenticateToEcr"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ProvisionPrivateNetworkAndCompute"
        Effect = "Allow"
        Action = [
          "ec2:AssociateRouteTable",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateLaunchTemplateVersion",
          "ec2:CreateRouteTable",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSubnet",
          "ec2:CreateTags",
          "ec2:CreateVpc",
          "ec2:CreateVpcEndpoint",
          "ec2:DeleteLaunchTemplate",
          "ec2:DeleteLaunchTemplateVersions",
          "ec2:DeleteRouteTable",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteSubnet",
          "ec2:DeleteTags",
          "ec2:DeleteVpc",
          "ec2:DeleteVpcEndpoints",
          "ec2:Describe*",
          "ec2:DisassociateRouteTable",
          "ec2:ModifyLaunchTemplate",
          "ec2:ModifySubnetAttribute",
          "ec2:ModifyVpcAttribute",
          "ec2:ModifyVpcEndpoint",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RunInstances",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ReadAttachedEcsManagedPolicies"
        Effect = "Allow"
        Action = ["iam:GetPolicy", "iam:GetPolicyVersion"]
        Resource = [
          "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
          "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
        ]
      },
      {
        Sid    = "ManageAutoscaling"
        Effect = "Allow"
        Action = [
          "autoscaling:CreateAutoScalingGroup",
          "autoscaling:DeleteAutoScalingGroup",
          "autoscaling:Describe*",
          "autoscaling:CreateOrUpdateTags",
          "autoscaling:DeleteTags",
          "autoscaling:PutScalingPolicy",
          "autoscaling:PutScheduledUpdateGroupAction",
          "autoscaling:ResumeProcesses",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:SuspendProcesses",
          "autoscaling:TagResource",
          "autoscaling:UntagResource",
          "autoscaling:UpdateAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ManageLoadBalancing"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
    ]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_policy" "github_actions_deploy_services" {
  name        = "${var.project_name}-github-actions-services"
  description = "Permissions for GitHub Actions to deploy this project's AWS services."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageEcs"
        Effect = "Allow"
        Action = [
          "ecs:CreateCluster",
          "ecs:CreateService",
          "ecs:DeleteCluster",
          "ecs:DeleteService",
          "ecs:DeregisterTaskDefinition",
          "ecs:Describe*",
          "ecs:List*",
          "ecs:PutClusterCapacityProviders",
          "ecs:RegisterTaskDefinition",
          "ecs:TagResource",
          "ecs:UntagResource",
          "ecs:UpdateCluster",
          "ecs:UpdateService",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ManageProjectGrafanaWorkspace"
        Effect = "Allow"
        Action = [
          "grafana:CreateWorkspace",
          "grafana:DeleteWorkspace",
          "grafana:DescribeWorkspace",
          "grafana:ListWorkspaces",
          "grafana:ListPermissions",
          "grafana:ListTagsForResource",
          "grafana:TagResource",
          "grafana:UntagResource",
          "grafana:UpdateWorkspace",
          "grafana:UpdatePermissions",
          "grafana:CreateWorkspaceApiKey",
          "grafana:DeleteWorkspaceApiKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.grafana_region
          }
        }
      },
      {
        Sid    = "ManageApiGateway"
        Effect = "Allow"
        Action = ["apigateway:*"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/restapis",
          "arn:aws:apigateway:${var.aws_region}::/restapis/*",
          "arn:aws:apigateway:${var.aws_region}::/vpclinks",
          "arn:aws:apigateway:${var.aws_region}::/vpclinks/*",
        ]
      },
      {
        Sid    = "TagProjectApiGatewayResources"
        Effect = "Allow"
        Action = ["apigateway:DELETE", "apigateway:PUT"]
        Resource = [
          "arn:aws:apigateway:${var.aws_region}::/tags/arn%3Aaws%3Aapigateway%3A${var.aws_region}%3A%3A%2Frestapis%2F*",
          "arn:aws:apigateway:${var.aws_region}::/tags/arn%3Aaws%3Aapigateway%3A${var.aws_region}%3A%3A%2Fvpclinks%2F*",
        ]
      },
      {
        Sid      = "ManageWebAcl"
        Effect   = "Allow"
        Action   = ["wafv2:*"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ManageProjectLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:ListTagsForResource",
          "logs:PutRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}*"
      },
      {
        Sid      = "ListProjectLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      },
      {
        Sid    = "ReadEcsOptimizedAmiParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = "arn:aws:ssm:${var.aws_region}::parameter/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
      },
      {
        Sid      = "ReadGrafanaAdminUserIds"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/grafana/admin-user-ids"
      },
    ]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_policy" "github_actions_deploy_iam" {
  name        = "${var.project_name}-github-actions-iam"
  description = "Permissions for GitHub Actions to manage this project's runtime IAM roles."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ManageProjectRuntimeRoles"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:PutRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:UpdateRole",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-grafana-workspace-role",
        ]
      },
      {
        Sid    = "CreateGrafanaWorkspaceRole"
        Effect = "Allow"
        Action = ["iam:CreateRole"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-grafana-workspace-role",
        ]
      },
      {
        Sid    = "CreateRuntimeRolesWithRequiredBoundary"
        Effect = "Allow"
        Action = ["iam:CreateRole"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
        ]
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.ecs_runtime_boundary_arn
          }
        }
      },
      {
        Sid    = "SetRequiredRuntimeRoleBoundary"
        Effect = "Allow"
        Action = ["iam:PutRolePermissionsBoundary"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
        ]
        Condition = {
          StringEquals = {
            "iam:PermissionsBoundary" = local.ecs_runtime_boundary_arn
          }
        }
      },
      {
        Sid    = "ManageProjectInstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:ListInstanceProfilesForRole",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:UntagInstanceProfile",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-instance-profile"
      },
      {
        Sid    = "AttachOnlyEcsManagedPolicies"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
        ]
        Condition = {
          ArnLike = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
              "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
            ]
          }
        }
      },
      {
        Sid    = "PassOnlyProjectRuntimeRolesToComputeServices"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-grafana-workspace-role",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "ec2.amazonaws.com",
              "ecs-tasks.amazonaws.com",
              "grafana.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid      = "CreateRequiredServiceLinkedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "autoscaling.amazonaws.com",
              "ecs.amazonaws.com",
              "elasticloadbalancing.amazonaws.com",
              "grafana.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid    = "ManageRuntimePermissionsBoundary"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicy",
          "iam:DeletePolicyVersion",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:SetDefaultPolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = local.ecs_runtime_boundary_arn
      },
      {
        Sid    = "ReadDeploymentRoleForTerraformRefresh"
        Effect = "Allow"
        Action = [
          "iam:GetOpenIDConnectProvider",
          "iam:GetRole",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListAttachedRolePolicies",
          "iam:ListOpenIDConnectProviderTags",
          "iam:ListPolicyTags",
          "iam:ListRoleTags",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-github-actions-deploy",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-deploy",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-services",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-iam",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-terraform-state",
        ]
      },
      {
        Sid    = "ManageOnlyProjectDeploymentPolicies"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:ListPolicyVersions",
          "iam:SetDefaultPolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-deploy",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-services",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-iam",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-github-actions-terraform-state",
        ]
      },
    ]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy_services" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_deploy_services.arn
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy_iam" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_deploy_iam.arn
}

resource "aws_iam_policy" "github_actions_terraform_state" {
  name        = "${var.project_name}-github-actions-terraform-state"
  description = "Access to this project's Terraform state and S3 state lock."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListTerraformStateObjects"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning",
          "s3:ListBucket",
        ]
        Resource = "arn:aws:s3:::${var.terraform_state_bucket}"
      },
      {
        Sid    = "ReadWriteTerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "arn:aws:s3:::${var.terraform_state_bucket}/heart-disease-api/terraform.tfstate"
      },
      {
        Sid    = "ManageTerraformStateLock"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::${var.terraform_state_bucket}/heart-disease-api/terraform.tfstate.tflock"
      },
    ]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_state" {
  role       = aws_iam_role.github_actions_deploy.name
  policy_arn = aws_iam_policy.github_actions_terraform_state.arn
}

output "github_actions_role_arn" {
  description = "Configure this ARN as the AWS_DEPLOY_ROLE_ARN GitHub Actions variable."
  value       = aws_iam_role.github_actions_deploy.arn
}
