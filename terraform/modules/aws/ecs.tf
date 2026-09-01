resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/ecs/${var.project_name}-proxy"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: lets ECS pull the image from ECR and ship container logs to
# CloudWatch. This is distinct from a task role (which the container itself
# would assume to call other AWS APIs) - the proxy doesn't call AWS APIs at
# runtime, so no task role is defined.
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "proxy" {
  family                   = "${var.project_name}-proxy"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name      = "proxy"
      image     = "${aws_ecr_repository.proxy.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        for key, value in var.environment : { name = key, value = value }
      ]
      # Resolved from Secrets Manager by the ECS agent at task start, so the
      # values never appear in the task definition itself.
      secrets = [
        for key, secret in aws_secretsmanager_secret.proxy :
        { name = key, valueFrom = secret.arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.proxy.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "proxy"
        }
      }
    }
  ])

  tags = {
    Name = "${var.project_name}-proxy"
  }
}

data "aws_region" "current" {}

resource "aws_ecs_service" "proxy" {
  name            = "${var.project_name}-proxy"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.proxy.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.proxy.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.proxy.arn
    container_name   = "proxy"
    container_port   = var.container_port
  }

  # Give a fresh task time to pass the ALB health check before ECS starts
  # counting its own health evaluation window.
  health_check_grace_period_seconds = 60

  # Secret *versions* hold the actual values the ECS agent fetches at task
  # start; without this the service can begin launching tasks before the
  # values exist and they fail with a ResourceNotFound on the secret.
  depends_on = [
    aws_secretsmanager_secret_version.proxy,
    aws_iam_role_policy.read_proxy_secrets,
    aws_lb_listener.http,
  ]
}
