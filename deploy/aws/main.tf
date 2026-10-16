terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.25, < 7.0"
    }
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

variable "instance_type" {
  description = "EC2 container-instance type."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t3.small"], var.instance_type)
    error_message = "instance_type must be t3.micro or t3.small."
  }
}

variable "image_tag" {
  description = "ECR tag for the serving container image."
  type        = string
  default     = "manual"
}

variable "grafana_admin_user_ids" {
  description = "IAM Identity Center user IDs to grant Grafana administrator access."
  type        = list(string)
  default     = []
}

variable "grafana_admin_group_ids" {
  description = "IAM Identity Center group IDs to grant Grafana administrator access."
  type        = list(string)
  default     = []
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "grafana"
  region = var.grafana_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_ecr_repository" "api" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_vpc" "api" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "${var.project_name}-vpc"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_subnet" "private_link" {
  count = 2

  vpc_id                  = aws_vpc.api.id
  cidr_block              = "10.20.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.project_name}-private-link-${count.index + 1}"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_subnet" "application" {
  count = 2

  vpc_id                  = aws_vpc.api.id
  cidr_block              = "10.20.${count.index + 11}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name      = "${var.project_name}-application-${count.index + 1}"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_route_table" "private_link" {
  count  = 2
  vpc_id = aws_vpc.api.id

  tags = {
    Name      = "${var.project_name}-private-link-${count.index + 1}"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_route_table_association" "private_link" {
  count = 2

  subnet_id      = aws_subnet.private_link[count.index].id
  route_table_id = aws_route_table.private_link[count.index].id
}

resource "aws_route_table" "application" {
  count  = 2
  vpc_id = aws_vpc.api.id

  tags = {
    Name      = "${var.project_name}-application-${count.index + 1}"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_route_table_association" "application" {
  count = 2

  subnet_id      = aws_subnet.application[count.index].id
  route_table_id = aws_route_table.application[count.index].id
}

resource "aws_security_group" "api_gateway_link" {
  name        = "${var.project_name}-apigw-link"
  description = "Security group for API Gateway private-link interfaces."
  vpc_id      = aws_vpc.api.id

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_security_group" "load_balancer" {
  name        = "${var.project_name}-alb"
  description = "Allow API traffic only from the API Gateway VPC link."
  vpc_id      = aws_vpc.api.id

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_security_group" "container_instance" {
  name        = "${var.project_name}-instance"
  description = "Allow API traffic from the ALB and HTTPS only to private endpoints."
  vpc_id      = aws_vpc.api.id

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-endpoints"
  description = "Allow private AWS service endpoint traffic from ECS instances."
  vpc_id      = aws_vpc.api.id

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_vpc_security_group_egress_rule" "api_gateway_to_alb" {
  security_group_id            = aws_security_group.api_gateway_link.id
  referenced_security_group_id = aws_security_group.load_balancer.id
  description                  = "API Gateway VPC link to internal ALB."
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_api_gateway" {
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.api_gateway_link.id
  description                  = "Only API Gateway VPC link can reach the internal ALB."
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instances" {
  security_group_id            = aws_security_group.load_balancer.id
  referenced_security_group_id = aws_security_group.container_instance.id
  description                  = "ALB forwards API traffic to ECS container instances."
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "instances_from_alb" {
  security_group_id            = aws_security_group.container_instance.id
  referenced_security_group_id = aws_security_group.load_balancer.id
  description                  = "Only the internal ALB can reach the API container port."
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "instances_to_endpoints" {
  security_group_id            = aws_security_group.container_instance.id
  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  description                  = "Private HTTPS access to required AWS service endpoints."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_instances" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.container_instance.id
  description                  = "Allow ECS instances to use private AWS service endpoints."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.aws_region}.s3"
}

resource "aws_vpc_security_group_egress_rule" "instances_to_s3" {
  security_group_id = aws_security_group.container_instance.id
  description       = "ECR image layer downloads through the private S3 gateway endpoint."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    "ecs",
    "ecs-agent",
    "ecs-telemetry",
    "ecr.api",
    "ecr.dkr",
    "logs",
  ])

  vpc_id              = aws_vpc.api.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.application[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name      = "${var.project_name}-${replace(each.value, ".", "-")}-endpoint"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.api.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.application[*].id

  tags = {
    Name      = "${var.project_name}-s3-endpoint"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_lb" "api" {
  name               = substr("${var.project_name}-alb", 0, 32)
  internal           = true
  load_balancer_type = "application"
  ip_address_type    = "ipv4"
  subnets            = aws_subnet.private_link[*].id
  security_groups    = [aws_security_group.load_balancer.id]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_lb_target_group" "api" {
  name        = substr("${var.project_name}-tg", 0, 32)
  port        = 8000
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.api.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_apigatewayv2_vpc_link" "api" {
  name               = "${var.project_name}-vpc-link"
  security_group_ids = [aws_security_group.api_gateway_link.id]
  subnet_ids         = aws_subnet.private_link[*].id

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_api_gateway_rest_api" "api" {
  name        = var.project_name
  description = "WAF-protected public API with a private ALB integration."

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.api.dns_name}/{proxy}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.api.id
  integration_target      = aws_lb.api.arn
  passthrough_behavior    = "WHEN_NO_MATCH"

  request_parameters = {
    "integration.request.path.proxy" = "method.request.path.proxy"
  }
}

resource "aws_api_gateway_method" "root" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_rest_api.api.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "root" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_rest_api.api.root_resource_id
  http_method             = aws_api_gateway_method.root.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.api.dns_name}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_apigatewayv2_vpc_link.api.id
  integration_target      = aws_lb.api.arn
  passthrough_behavior    = "WHEN_NO_MATCH"
}

resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  triggers = {
    redeployment = sha1(jsonencode({
      proxy_resource   = aws_api_gateway_resource.proxy.id
      proxy_method     = aws_api_gateway_method.proxy.http_method
      proxy_uri        = aws_api_gateway_integration.proxy.uri
      proxy_vpc_link   = aws_api_gateway_integration.proxy.connection_id
      proxy_target     = aws_api_gateway_integration.proxy.integration_target
      proxy_parameters = aws_api_gateway_integration.proxy.request_parameters
      root_method      = aws_api_gateway_method.root.http_method
      root_uri         = aws_api_gateway_integration.root.uri
      root_vpc_link    = aws_api_gateway_integration.root.connection_id
      root_target      = aws_api_gateway_integration.root.integration_target
    }))
  }

  depends_on = [
    aws_api_gateway_integration.proxy,
    aws_api_gateway_integration.root,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api" {
  deployment_id = aws_api_gateway_deployment.api.id
  rest_api_id   = aws_api_gateway_rest_api.api.id
  stage_name    = "prod"

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_wafv2_web_acl" "api" {
  name        = "${var.project_name}-web-acl"
  description = "AWS managed protections for the public API Gateway endpoint."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = "arn:aws:apigateway:${var.aws_region}::/restapis/${aws_api_gateway_rest_api.api.id}/stages/${aws_api_gateway_stage.api.stage_name}"
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

resource "aws_ecs_cluster" "api" {
  name = var.project_name

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role" "container_instance" {
  name                 = "${var.project_name}-instance-role"
  permissions_boundary = aws_iam_policy.ecs_runtime_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "container_instance" {
  role       = aws_iam_role.container_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "container_instance" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.container_instance.name

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role" "task_execution" {
  name                 = "${var.project_name}-task-execution-role"
  permissions_boundary = aws_iam_policy.ecs_runtime_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 14

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role" "grafana_workspace" {
  name = "${var.project_name}-grafana-workspace-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "grafana.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch_logs" {
  name = "${var.project_name}-grafana-cloudwatch-logs"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DiscoverLogGroups"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "ValidateCloudWatchDataSource"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        Sid      = "StartQueriesAgainstApiLogGroup"
        Effect   = "Allow"
        Action   = ["logs:StartQuery"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
      {
        Sid    = "ReadAndStopLogInsightsQueries"
        Effect = "Allow"
        Action = [
          "logs:GetQueryResults",
          "logs:StopQuery",
        ]
        Resource = "*"
      },
      {
        Sid    = "ReadApiLogEvents"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:FilterLogEvents",
          "logs:GetLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      },
    ]
  })
}

resource "aws_grafana_workspace" "api" {
  provider                 = aws.grafana
  name                     = "${var.project_name}-cloudwatch-grafana-singapore"
  description              = "CloudWatch Logs dashboard for the Heart Disease API in Singapore."
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "CUSTOMER_MANAGED"
  role_arn                 = aws_iam_role.grafana_workspace.arn
  data_sources             = ["CLOUDWATCH"]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }

  depends_on = [
    aws_iam_role_policy.grafana_cloudwatch_logs,
  ]
}

resource "aws_grafana_role_association" "admins" {
  provider = aws.grafana
  count    = length(var.grafana_admin_user_ids) + length(var.grafana_admin_group_ids) > 0 ? 1 : 0

  workspace_id = aws_grafana_workspace.api.id
  role         = "ADMIN"
  user_ids     = var.grafana_admin_user_ids
  group_ids    = var.grafana_admin_group_ids
}

resource "aws_launch_template" "container_instance" {
  name_prefix   = "${var.project_name}-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.container_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.container_instance.id]
  user_data = base64encode(join("\n", [
    "#!/bin/bash",
    "echo \"ECS_CLUSTER=${aws_ecs_cluster.api.name}\" >> /etc/ecs/ecs.config",
    "",
  ]))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name      = "${var.project_name}-ecs-instance"
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_autoscaling_group" "container_instance" {
  name                = "${var.project_name}-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = aws_subnet.application[*].id

  launch_template {
    id      = aws_launch_template.container_instance.id
    version = "$Latest"
  }

  depends_on = [
    aws_route_table_association.application,
    aws_vpc_security_group_egress_rule.instances_to_endpoints,
    aws_vpc_security_group_egress_rule.instances_to_s3,
    aws_vpc_security_group_ingress_rule.endpoints_from_instances,
    aws_vpc_endpoint.interface,
    aws_vpc_endpoint.s3,
    aws_iam_role_policy_attachment.container_instance,
  ]

  tag {
    key                 = "Name"
    value               = "${var.project_name}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "Terraform"
    propagate_at_launch = true
  }
}

resource "aws_ecs_task_definition" "api" {
  family                   = var.project_name
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn

  container_definitions = jsonencode([
    {
      name      = var.project_name
      image     = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
      essential = true
      memory    = 512
      portMappings = [{
        containerPort = 8000
        hostPort      = 8000
        protocol      = "tcp"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_ecs_service" "api" {
  name                               = var.project_name
  cluster                            = aws_ecs_cluster.api.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = 1
  launch_type                        = "EC2"
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 90
  wait_for_steady_state              = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = var.project_name
    container_port   = 8000
  }

  depends_on = [
    aws_lb_listener.http,
    aws_autoscaling_group.container_instance,
    aws_iam_role_policy_attachment.task_execution,
  ]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

output "api_url" {
  description = "Public HTTPS API Gateway URL of the heart disease API."
  value       = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.api.stage_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL for the serving image."
  value       = aws_ecr_repository.api.repository_url
}

output "health_url" {
  description = "Health check endpoint."
  value       = "${aws_api_gateway_stage.api.invoke_url}/health"
}

output "predict_url" {
  description = "Prediction endpoint."
  value       = "${aws_api_gateway_stage.api.invoke_url}/predict"
}

output "private_alb_dns_name" {
  description = "Private DNS name of the internal application load balancer."
  value       = aws_lb.api.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.api.name
}

output "ecs_service_name" {
  value = aws_ecs_service.api.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.api.name
}

output "grafana_workspace_id" {
  description = "AWS Managed Grafana workspace ID."
  value       = aws_grafana_workspace.api.id
}

output "grafana_workspace_endpoint" {
  description = "AWS Managed Grafana workspace base URL."
  value       = aws_grafana_workspace.api.endpoint
}

output "grafana_workspace_region" {
  description = "AWS region of the Managed Grafana workspace."
  value       = var.grafana_region
}

output "grafana_dashboard_url" {
  description = "URL of the provisioned API CloudWatch dashboard."
  value       = "${trimsuffix(aws_grafana_workspace.api.endpoint, "/")}/d/heart-disease-api-cloudwatch/heart-disease-api-cloudwatch?orgId=1"
}
