resource "aws_security_group" "proxy" {
  name_prefix = "${var.project_name}-proxy-"
  description = "Allow inbound access to the FastAPI EIS proxy and unrestricted egress to Elastic Serverless."
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.project_name}-proxy-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Tasks accept traffic ONLY from the ALB. Even though tasks carry public IPs
# (needed for ECR pulls without a NAT gateway), port 8000 is not reachable
# from the internet directly - clients must come through the ALB, whose own
# SG enforces var.allowed_cidr_blocks (see alb.tf).
resource "aws_vpc_security_group_ingress_rule" "proxy_from_alb" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "Proxy traffic from the ALB only"
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "proxy_all" {
  security_group_id = aws_security_group.proxy.id
  description       = "Outbound to Elastic Serverless (HTTPS) and ECR/CloudWatch"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
