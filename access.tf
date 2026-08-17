# ---------------------------------------------------------------------------
# Teammate access to the ui/api instances via SSM Session Manager
#
# No SSH, no bastion, no key management — matches how this stack already
# runs (see security_groups.tf: there is no port 22 rule anywhere). Access is
# scoped by instance tag rather than instance ID, so it keeps working across
# the instance replacements this stack does on every user_data change.
# ---------------------------------------------------------------------------

variable "ssm_user_names" {
  description = "Existing IAM usernames to grant SSM Session Manager access to the ui/api instances. Users are not created here — they must already exist."
  type        = list(string)
  default     = []
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ssm_session_access" {
  statement {
    sid       = "StartSessionOnAppInstances"
    actions   = ["ssm:StartSession"]
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
  }

  statement {
    sid       = "ManageOwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"]
  }

  statement {
    sid = "SessionManagerReadOnly"
    actions = [
      "ssm:DescribeSessions",
      "ssm:GetConnectionStatus",
      "ssm:DescribeInstanceInformation",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "ssm_session_access" {
  name        = "${local.name}-ssm-session-access"
  description = "Session Manager shell access to the ui/api instances only. No SSH, no key management, every session logged in CloudTrail."
  policy      = data.aws_iam_policy_document.ssm_session_access.json
}

resource "aws_iam_group" "ssm_users" {
  name = "${local.name}-ssm-users"
}

resource "aws_iam_group_policy_attachment" "ssm_session_access" {
  group      = aws_iam_group.ssm_users.name
  policy_arn = aws_iam_policy.ssm_session_access.arn
}

# Authoritative for THIS group's membership only — doesn't touch any other
# group a listed user might already belong to.
resource "aws_iam_group_membership" "ssm_users" {
  name  = "${local.name}-ssm-users-membership"
  group = aws_iam_group.ssm_users.name
  users = var.ssm_user_names
}
