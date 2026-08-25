# ---------------------------------------------------------------------------
# CI deploy credentials — SSM Run Command, not SSH.
#
# Both app repos' GitHub Actions workflows used to SSH into the private
# instances via the bastion to redeploy. That path was broken two ways: the
# instances never had the deploy key installed (no key_name was ever set on
# aws_instance.ui/api), and the SSH-based deploy scripts themselves had
# drifted from what Terraform actually runs (wrong container name, wrong
# image tag, wrong port, and a hardcoded private IP that goes stale the next
# time Terraform replaces the instance).
#
# Rather than opening port 22 and reintroducing SSH to instances that
# currently have none, each repo gets its own narrowly-scoped IAM user that
# can only run ssm:SendCommand against instances tagged for its own tier —
# same tag-based scoping pattern as access.tf, just for a CI principal
# instead of a human one. No bastion dependency, no SSH key, no hardcoded IP:
# the workflow resolves the current instance ID by tag at deploy time.
# ---------------------------------------------------------------------------

locals {
  ci_deploy_tiers = {
    api = "fleetDriverAssistance"
    ui  = "fleet-agent-ai"
  }
}

resource "aws_iam_user" "ci_deploy" {
  for_each = local.ci_deploy_tiers
  name     = "${local.name}-ci-deploy-${each.key}"
}

data "aws_iam_policy_document" "ci_deploy" {
  for_each = local.ci_deploy_tiers

  # Split into two statements on purpose: SendCommand checks permissions
  # against BOTH resources involved (the document and the target instance).
  # A tag condition like ssm:resourceTag/Tier only resolves against the
  # instance — putting it in a statement that also lists the document
  # resource makes AWS evaluate that same condition against the document
  # too, which has no such tag and so gets silently denied. Confirmed by
  # actually testing with the scoped CI credentials, not just plan/apply.
  statement {
    sid       = "SendCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "SendCommandToOwnTierOnly"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project]
    }
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/ManagedBy"
      values   = ["terraform"]
    }
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Tier"
      values   = [each.key]
    }
  }

  statement {
    sid = "CheckCommandStatus"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ci_deploy" {
  for_each = local.ci_deploy_tiers
  name     = "${local.name}-ci-deploy-${each.key}"
  user     = aws_iam_user.ci_deploy[each.key].name
  policy   = data.aws_iam_policy_document.ci_deploy[each.key].json
}

resource "aws_iam_access_key" "ci_deploy" {
  for_each = local.ci_deploy_tiers
  user     = aws_iam_user.ci_deploy[each.key].name
}

output "ci_deploy_access_key_ids" {
  description = "Access key IDs per tier — not secret, safe to display."
  value       = { for k, v in aws_iam_access_key.ci_deploy : k => v.id }
}

output "ci_deploy_secret_access_keys" {
  description = "Secret keys per tier. Sensitive — pull with: terraform output -json ci_deploy_secret_access_keys"
  value       = { for k, v in aws_iam_access_key.ci_deploy : k => v.secret }
  sensitive   = true
}
