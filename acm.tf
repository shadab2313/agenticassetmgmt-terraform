# ---------------------------------------------------------------------------
# TLS certificate
#
# DNS for the domain lives in Cloudflare, not Route 53, so this stack cannot
# create the validation record itself. It requests the certificate and
# outputs the CNAME to add in Cloudflare; ACM issues the certificate on its
# own once that record resolves. The ALB listener does NOT attach it
# automatically, though: AWS rejects a certificate_arn that isn't ISSUED yet,
# so a second apply is required after validation — see the has_https comment
# below.
# ---------------------------------------------------------------------------

resource "aws_acm_certificate" "main" {
  count = var.domain_name == "" ? 0 : 1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # ALB refuses to attach a certificate that isn't ISSUED yet, so the HTTPS
  # listener can only turn on for an already-validated, explicitly supplied
  # certificate_arn. Setting domain_name alone just requests the certificate
  # and stops there — it does not flip the listener on by itself. Once ACM
  # shows the cert as ISSUED (check `terraform output acm_certificate_status`
  # or the console), copy its ARN into certificate_arn and apply again to
  # attach it.
  certificate_arn = var.certificate_arn
  has_https       = var.certificate_arn != ""
}
