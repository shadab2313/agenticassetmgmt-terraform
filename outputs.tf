output "app_url" {
  description = "Point a Route 53 alias record at the ALB, or hit this directly to test."
  value       = local.has_https ? "https://${aws_lb.main.dns_name}" : "http://${aws_lb.main.dns_name}"
}

output "acm_certificate_arn" {
  description = "Certificate bound to the ALB's HTTPS listener."
  value       = local.certificate_arn
}

output "acm_certificate_status" {
  description = "PENDING_VALIDATION until the CNAME below resolves, then ISSUED. No terraform apply needed for that transition — AWS updates it in the background."
  value       = var.domain_name == "" || var.certificate_arn != "" ? null : aws_acm_certificate.main[0].status
}

output "acm_validation_record" {
  description = "Add this CNAME in Cloudflare (DNS only, not proxied) to validate the certificate."
  value = var.domain_name == "" || var.certificate_arn != "" ? null : {
    name  = tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_name
    type  = tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_type
    value = tolist(aws_acm_certificate.main[0].domain_validation_options)[0].resource_record_value
  }
}

output "alb_dns_name" {
  description = "Target for a Route 53 alias record."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Hosted zone ID needed for the Route 53 alias record."
  value       = aws_lb.main.zone_id
}

output "vpc_id" {
  description = "The pre-existing VPC this deployed into. Not managed by this stack."
  value       = data.aws_vpc.main.id
}

output "security_group_ids" {
  description = "Groups created by this stack. Your database keeps its own."
  value = {
    alb = aws_security_group.alb.id
    ui  = aws_security_group.ui.id
    api = aws_security_group.api.id
  }
}

output "database_access" {
  description = "Rule added to your database's existing security group."
  value       = "Ingress on port ${var.db_port} added to ${var.existing_db_security_group_id}, source ${aws_security_group.api.id}."
}

output "api_role_name" {
  description = "Grant this role any further permissions your backend needs."
  value       = aws_iam_role.instance.name
}

output "instance_ids" {
  description = "Feed one of these to: aws ssm start-session --target <id>"
  value = {
    ui  = aws_instance.ui[*].id
    api = aws_instance.api[*].id
  }
}

output "availability_zone" {
  description = "Single AZ everything runs in. The ALB spans two by necessity."
  value       = local.primary_az
}
