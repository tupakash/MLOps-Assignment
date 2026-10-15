variable "github_repository" {
  description = "GitHub owner/repository allowed to assume the deployment role."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use the owner/repository format."
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

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_policy" "ecs_runtime_boundary" {
  name        = "${var.project_name}-ecs-runtime-boundary"
  description = "Permissions boundary for ECS container-instance and task-execution roles."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EcsContainerInstance"
        Effect = "Allow"
        Action = [
          "ecs:DiscoverPollEndpoint",
          "ecs:RegisterContainerInstance",
          "ecs:DeregisterContainerInstance",
          "ecs:Submit*",
          "ecs:Poll",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
          "ecs:Describe*",
          "ecs:List*",
          "ec2:Describe*",
        ]
        Resource = "*"
      },
      {
        Sid    = "PullEcrImages"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
      {
        Sid    = "WriteContainerLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}:*"
      },
    ]
  })

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
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:ref:refs/heads/${var.github_deploy_branch}"
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
        Sid      = "ManageApiGateway"
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = "arn:aws:apigateway:${var.aws_region}::/restapis/${aws_api_gateway_rest_api.api.id}*"
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
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
          "logs:PutRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}*"
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
        Sid    = "ManageProjectRuntimeRoles"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
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
            "iam:PermissionsBoundary" = aws_iam_policy.ecs_runtime_boundary.arn
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
            "iam:PermissionsBoundary" = aws_iam_policy.ecs_runtime_boundary.arn
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
        Sid      = "PassOnlyProjectRuntimeRolesToComputeServices"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-instance-role",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-task-execution-role",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = [
              "ec2.amazonaws.com",
              "ecs-tasks.amazonaws.com",
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
            ]
          }
        }
      },
      {
        Sid    = "ManageRuntimePermissionsBoundary"
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
        ]
        Resource = aws_iam_policy.ecs_runtime_boundary.arn
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

output "github_actions_role_arn" {
  description = "Configure this ARN as the AWS_DEPLOY_ROLE_ARN GitHub Actions variable."
  value       = aws_iam_role.github_actions_deploy.arn
}
