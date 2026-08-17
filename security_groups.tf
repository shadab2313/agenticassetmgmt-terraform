# Every rule below references another security group rather than a CIDR.
# This is the whole point: no hardcoded IPs, and the rules keep working as
# instances are replaced.
#
# Rules live in separate aws_vpc_security_group_*_rule resources rather than
# inline blocks. Inline rules would create a dependency cycle between the UI
# and API groups, and they also fight with anything changed outside Terraform.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public entry point. Only group allowed inbound from the internet."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-alb" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "ui" {
  name        = "${local.name}-ui"
  description = "UI servers. Reachable only from the load balancer."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-ui" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "api" {
  name        = "${local.name}-api"
  description = "Backend API. Reachable from the load balancer and the UI tier."
  vpc_id      = var.vpc_id

  tags = { Name = "${local.name}-api" }

  lifecycle {
    create_before_destroy = true
  }
}

# No database security group here. The database already exists and has one;
# see database.tf, which adds a rule to it rather than creating a new group.

# ---------------------------------------------------------------------------
# ALB: the only thing open to the world
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = var.certificate_arn == "" ? 0 : 1

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = var.certificate_arn == "" ? "HTTP from the internet" : "HTTP from the internet, redirected to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ui" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to UI target group"
  referenced_security_group_id = aws_security_group.ui.id
  from_port                    = var.ui_port
  to_port                      = var.ui_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to API target group"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = var.api_port
  to_port                      = var.api_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# UI tier
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "ui_from_alb" {
  security_group_id            = aws_security_group.ui.id
  description                  = "App traffic and health checks from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.ui_port
  to_port                      = var.ui_port
  ip_protocol                  = "tcp"
}

# Outbound is open so instances can install packages and reach SSM. Tighten
# to VPC endpoints later if your compliance posture requires it.
resource "aws_vpc_security_group_egress_rule" "ui_all" {
  security_group_id = aws_security_group.ui.id
  description       = "Outbound via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# API tier
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "Path-routed /api/* traffic and health checks from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.api_port
  to_port                      = var.api_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_ui" {
  security_group_id            = aws_security_group.api.id
  description                  = "Server-side calls from the UI tier"
  referenced_security_group_id = aws_security_group.ui.id
  from_port                    = var.api_port
  to_port                      = var.api_port
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_all" {
  security_group_id = aws_security_group.api.id
  description       = "Outbound via NAT"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Note the absence of a port 22 rule anywhere in this file. Shell access goes
# through SSM Session Manager, which uses the AWS API rather than an inbound
# port. See the IAM role in compute.tf.
