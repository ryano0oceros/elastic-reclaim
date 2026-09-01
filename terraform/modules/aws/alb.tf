# Application Load Balancer in front of the Fargate service.
#
# Exists primarily to give developers a STABLE hostname: a Fargate task's
# public IP changes on every deployment, which broke every developer's
# config each time the proxy shipped. The ALB DNS name survives deploys.
#
# HTTP-only listener for now - TLS is a documented future enhancement that
# needs a real domain + ACM certificate (see README "Future enhancements").
# When SSO lands, its authenticate-oidc action attaches to this listener
# (see ../sso).

resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "Inbound HTTP to the EIS proxy ALB."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-alb-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.allowed_cidr_blocks)
  security_group_id = aws_security_group.alb.id
  description       = "OpenCode/OpenAI-compatible clients reaching the proxy via the ALB"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to Fargate tasks"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.proxy.id
}

resource "aws_lb" "proxy" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}-alb"
  }
}

resource "aws_lb_target_group" "proxy" {
  name        = "${var.project_name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip" # Fargate awsvpc tasks register by IP

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Long-lived SSE streams: don't sever an in-flight completion on deploy.
  deregistration_delay = 60
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.proxy.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }
}
