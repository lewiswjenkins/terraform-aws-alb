module "default_label" {
  source      = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.16.0"
  attributes  = var.attributes
  delimiter   = var.delimiter
  name        = var.name
  namespace   = var.namespace
  stage       = var.stage
  environment = var.environment
  tags        = var.tags
}

resource "aws_security_group" "default" {
  description = "Controls access to the ALB (HTTP/HTTPS)"
  vpc_id      = var.vpc_id
  name        = module.default_label.id
  tags        = module.default_label.tags
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = "0"
  to_port           = "0"
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.default.id
}

resource "aws_security_group_rule" "http_ingress" {
  count             = var.http_enabled ? 1 : 0
  type              = "ingress"
  from_port         = var.http_port
  to_port           = var.http_port
  protocol          = "tcp"
  cidr_blocks       = var.http_ingress_cidr_blocks
  prefix_list_ids   = var.http_ingress_prefix_list_ids
  security_group_id = aws_security_group.default.id
}

resource "aws_security_group_rule" "https_ingress" {
  count             = var.https_enabled ? 1 : 0
  type              = "ingress"
  from_port         = var.https_port
  to_port           = var.https_port
  protocol          = "tcp"
  cidr_blocks       = var.https_ingress_cidr_blocks
  prefix_list_ids   = var.https_ingress_prefix_list_ids
  security_group_id = aws_security_group.default.id
}

module "access_logs" {
  source        = "git::https://github.com/cloudposse/terraform-aws-lb-s3-bucket.git?ref=tags/0.3.0"
  enabled       = var.access_logs_enabled
  name          = var.name
  namespace     = var.namespace
  stage         = var.stage
  environment   = var.environment
  attributes    = compact(concat(var.attributes, ["alb", "access", "logs"]))
  delimiter     = var.delimiter
  tags          = var.tags
  region        = var.access_logs_region
  force_destroy = var.alb_access_logs_s3_bucket_force_destroy
}

resource "aws_lb" "default" {
  name               = module.default_label.id
  tags               = module.default_label.tags
  internal           = var.internal
  load_balancer_type = "application"

  security_groups = compact(
    concat(var.security_group_ids, [aws_security_group.default.id]),
  )

  subnets                          = var.subnet_ids
  enable_cross_zone_load_balancing = var.cross_zone_load_balancing_enabled
  enable_http2                     = var.http2_enabled
  idle_timeout                     = var.idle_timeout
  ip_address_type                  = var.ip_address_type
  enable_deletion_protection       = var.deletion_protection_enabled

  access_logs {
    bucket  = module.access_logs.bucket_id
    prefix  = var.access_logs_prefix
    enabled = var.access_logs_enabled
  }
}

module "default_target_group_label" {
  source      = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.16.0"
  attributes  = concat(var.attributes, ["default"])
  delimiter   = var.delimiter
  name        = var.name
  namespace   = var.namespace
  stage       = var.stage
  environment = var.environment
  tags        = var.tags
}

resource "random_id" "alb_tg" {
  byte_length = 8
  keepers = {
    name                 = var.target_group_name
    port                 = var.target_group_port
    protocol             = var.target_group_protocol
    vpc_id               = var.vpc_id
    target_type          = var.target_group_target_type
  }
}

resource "aws_lb_target_group" "default" {
  name                 = var.target_group_name == "" ? join(module.default_target_group_label.delimiter, [module.default_target_group_label.id ,random_id.alb_tg.hex]) : var.target_group_name
  port                 = var.target_group_port
  protocol             = var.target_group_protocol
  vpc_id               = var.vpc_id
  target_type          = var.target_group_target_type
  deregistration_delay = var.deregistration_delay

  health_check {
    path                = var.health_check_path
    timeout             = var.health_check_timeout
    healthy_threshold   = var.health_check_healthy_threshold
    unhealthy_threshold = var.health_check_unhealthy_threshold
    interval            = var.health_check_interval
    matcher             = var.health_check_matcher
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(
    module.default_target_group_label.tags,
    var.target_group_additional_tags
  )
}

resource "aws_lb_listener" "http_forward" {
  count             = var.http_enabled && var.http_redirect != true ? 1 : 0
  load_balancer_arn = aws_lb.default.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.default.arn
    type             = "forward"
  }
}

resource "aws_lb_listener" "http_redirect" {
  count             = var.http_enabled && var.http_redirect == true ? 1 : 0
  load_balancer_arn = aws_lb.default.arn
  port              = var.http_port
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.default.arn
    type             = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = var.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.default.arn

  port            = var.https_port
  protocol        = "HTTPS"
  ssl_policy      = var.https_ssl_policy
  certificate_arn = var.certificate_arn

  default_action {
    target_group_arn = aws_lb_target_group.default.arn
    type             = "forward"
  }
}
