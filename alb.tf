locals {
  default_target_group_arn = var.alb_default_target == "api" ? aws_lb_target_group.api.arn : aws_lb_target_group.ui.arn

  # When the API is already the default, a rule sending /api/* to the API is
  # redundant. Skip it rather than creating a no-op.
  create_api_path_rule = var.alb_default_target != "api"
}

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"

  tags = { Name = "${local.name}-alb" }
}

# ---------------------------------------------------------------------------
# Target groups
#
# The health check path is the single most common reason a deploy comes up
# with everything marked unhealthy.
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "ui" {
  name     = "${local.name}-tg-ui"
  port     = var.ui_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.ui_health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_target_group" "api" {
  name     = "${local.name}-tg-api"
  port     = var.api_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = var.api_health_check_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Listeners
# ---------------------------------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.certificate_arn == "" ? [] : [1]
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = var.certificate_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = local.default_target_group_arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn == "" ? 0 : 1

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = local.default_target_group_arn
  }
}

# ---------------------------------------------------------------------------
# Path routing
#
# Only created when the UI is the default target. With alb_default_target set
# to "api", everything already reaches the backend and this rule is skipped.
# ---------------------------------------------------------------------------

resource "aws_lb_listener_rule" "api" {
  count = local.create_api_path_rule ? 1 : 0

  listener_arn = var.certificate_arn == "" ? aws_lb_listener.http.arn : aws_lb_listener.https[0].arn
  priority     = 100

  condition {
    path_pattern {
      values = var.api_path_patterns
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}