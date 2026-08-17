# Connectivity to the database that already exists in this VPC. Nothing here
# creates a database.
#
# Because the app and the database share a VPC, the API tier's security group
# can be referenced directly from the database's group. No CIDR blocks, no
# peering, and the rule keeps working as instances are replaced.

# ---------------------------------------------------------------------------
# Allow the API tier into the database's existing security group.
#
# This mutates a group Terraform did not create. That is the correct pattern,
# but note the rule will be removed on `terraform destroy`. The group itself
# and every other rule on it are left alone.
# ---------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "existing_db_from_api" {
  security_group_id            = var.existing_db_security_group_id
  description                  = "${local.name} API tier"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# Let the API role read the database credentials, if you keep them in
# Secrets Manager. Leave existing_db_secret_arn empty to skip.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "db_secret_read" {
  count = var.existing_db_secret_arn == "" ? 0 : 1

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.existing_db_secret_arn]
  }
}

resource "aws_iam_role_policy" "db_secret_read" {
  count = var.existing_db_secret_arn == "" ? 0 : 1

  name   = "${local.name}-db-secret-read"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.db_secret_read[0].json
}
