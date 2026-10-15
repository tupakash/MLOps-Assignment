data "aws_caller_identity" "current" {}

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
