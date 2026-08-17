# Terraform setup, explained file by file

This is a line-by-line walkthrough of every `.tf` file in this repo: what each resource does, why it's written the way it is, and how the files depend on each other. If you just want to deploy, see `README.md` instead — this doc is for understanding what actually happens when you run `terraform apply`.

## Mental model first

Before the files make sense individually, the one idea that explains most of the design choices in this repo:

**This stack manages a UI tier, an API tier, and an ALB in front of them. It does not manage the VPC, subnets, NAT gateway, route tables, or database — those already exist, and this stack only reads them (via `data` blocks) or, in two deliberate cases, mutates one narrow thing about them without taking ownership of the whole resource.**

Those two exceptions are worth knowing up front because they explain otherwise-surprising code:
- `database.tf` adds one ingress rule to the database's *existing* security group — it doesn't create or own that group.
- `nat_instance.tf` manages one route (`0.0.0.0/0`) in the *existing* private route table — it doesn't own the route table.

Everything else in the network (VPC, subnets, NAT gateway itself, route tables) is a `data` lookup: Terraform reads it, validates it, and never writes to it.

The other running theme: **every security group rule references another security group, never a raw IP** (except for the ALB's public-facing rules, which by definition must allow `0.0.0.0/0`). This is why `security_groups.tf` creates the groups but leaves them empty, and separate files add rules that reference `aws_security_group.ui.id`, `aws_security_group.api.id`, etc. A rule that says "allow traffic from the ALB's security group" keeps working forever, even when the ALB's underlying IPs change. A rule with a hardcoded CIDR would need updating by hand.

---

## `versions.tf` — provider setup

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # backend "s3" { ... }  (commented out)
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

- `required_version >= 1.5.0` — pins the minimum Terraform CLI version. `1.5.0` is where `precondition`/`postcondition` blocks (used in `network.tf`) became stable.
- `required_providers.aws.version = "~> 5.60"` — the `~>` operator means "5.60 or higher, but not 6.0" (a pessimistic version constraint). This is what `.terraform.lock.hcl` pins to an exact resolved version once you run `terraform init`.
- The commented-out `backend "s3"` block is the reason state currently lives in `terraform.tfstate` on disk (and is gitignored — see below). Uncommenting it and re-running `terraform init` would migrate state to S3, which is the right move the moment more than one person runs `apply` against this stack.
- `provider "aws" { region = var.region }` — every resource in every file inherits this region unless it explicitly overrides it. There's exactly one region in play here (`us-east-1`, set in `terraform.tfvars`).
- `default_tags` — this is why every resource you look up in the AWS console has `Project`, `Environment`, and `ManagedBy = terraform` tags without any individual resource block setting them. It's also load-bearing for `access.tf`'s IAM policy, which scopes SSM access by matching on the `Project` and `ManagedBy` tags this block sets automatically.

---

## `variables.tf` — every input this stack accepts

This file has no resources, only `variable` blocks. Grouped by section:

**Identity (`project`, `environment`, `region`)** — feed `local.name` (defined in `network.tf` as `"${var.project}-${var.environment}"`), which is why every resource name in this stack looks like `agentic-asset-dev-*`.

**Existing network (`vpc_id`, `alb_subnet_ids`, `app_subnet_ids`)** — the three required inputs describing where to deploy. Each has a `validation` block:
- `vpc_id` must match `^vpc-` via regex — catches a copy-paste mistake (e.g. pasting a subnet ID here) at `plan` time instead of a confusing AWS API error later.
- `alb_subnet_ids` must have `length >= 2` — a raw Terraform-level check. `network.tf`'s precondition later does the *real* check (that they're in two different AZs, which AWS actually requires for an ALB).
- `app_subnet_ids` must have at least 1 entry.

**Application ports (`ui_port`, `api_port`, health check paths, `api_path_patterns`)** — these flow into `alb.tf` (target group ports, health checks) and `security_groups.tf` (which ports the security group rules open).

**TLS (`domain_name`, `certificate_arn`)** — covered in depth under `acm.tf` below, since the two variables' interaction is the interesting part.

**Compute (`ui_instance_type`, `api_instance_type`, counts)** — defaults to `t3.small` × 1 each. `ui_instance_count`/`api_instance_count` directly become the `count` on `aws_instance.ui`/`aws_instance.api` in `compute.tf`.

**Existing database (`db_port`, `existing_db_security_group_id`, `existing_db_host`, `existing_db_secret_arn`)** — `existing_db_security_group_id` has the same regex-validation pattern as `vpc_id`, this time for `^sg-`. These four variables are the entire interface to `database.tf`.

**`alb_default_target`** — `"ui"` or `"api"`, validated by a `contains()` check. This one variable controls a fair amount of conditional logic in `alb.tf` (see `local.default_target_group_arn` and `local.create_api_path_rule`).

**Container images (`api_image`, `api_container_port`, `ui_image`, `ui_container_port`)** — each defaults to `""`. Empty string is a real, intentional third state (not just "unset") — see `compute.tf`'s `user_data` templating below, which branches on exactly this.

---

## `network.tf` — reads the existing VPC, validates it, creates nothing

```hcl
locals {
  name = "${var.project}-${var.environment}"
}

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_subnet" "alb" {
  for_each = toset(var.alb_subnet_ids)
  id       = each.value
}

data "aws_subnet" "app" {
  for_each = toset(var.app_subnet_ids)
  id       = each.value
}
```

- `local.name` is defined here (not in `variables.tf`) because it's the first thing every other file needs, and this file loads conceptually "first" in the mental model even though Terraform doesn't actually care about file order — it builds a dependency graph from resource references, not a top-to-bottom script.
- `data "aws_vpc" "main"` — a read-only lookup, confirms the VPC exists and exposes its attributes (like CIDR) to other files if needed.
- The two `data "aws_subnet"` blocks use `for_each` over a `toset()` of the ID list, not `count`. This matters: with `for_each`, each subnet is addressed by its own ID as the map key (`data.aws_subnet.alb["subnet-09d37..."]`), so if you ever *remove* one subnet from the list, Terraform only drops that one entry from state. With `count`, removing an entry from the middle of the list would shift every subsequent index and cause Terraform to think several subnets changed identity. `for_each` is the correct choice whenever the "things you're looping over" have a natural unique key (here, the subnet ID itself).

```hcl
resource "terraform_data" "network_checks" {
  lifecycle {
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.alb : s.availability_zone])) >= 2
      error_message = "alb_subnet_ids must cover at least two availability zones..."
    }
    precondition {
      condition     = alltrue([for s in data.aws_subnet.alb : s.vpc_id == var.vpc_id])
      error_message = "Every subnet in alb_subnet_ids must belong to vpc_id."
    }
    precondition {
      condition     = alltrue([for s in data.aws_subnet.app : s.vpc_id == var.vpc_id])
      error_message = "Every subnet in app_subnet_ids must belong to vpc_id."
    }
  }
}
```

`terraform_data` is a no-op resource type — it manages nothing in AWS. It exists here purely as a place to hang `precondition` blocks that need to reference data sources (`aws_lb`'s own preconditions can't easily reference `data.aws_subnet`, since the ALB's subnet AZs are only knowable after those data sources resolve). Each `precondition` is a `condition` (must evaluate `true`) paired with a readable `error_message`. Three checks:
1. The ALB's subnets span at least 2 distinct AZs — `distinct([...])` dedupes the AZ list, so `length >= 2` means "not all in the same AZ."
2. Every ALB subnet actually belongs to `var.vpc_id` (catches pasting a subnet ID from the wrong VPC).
3. Same check for app subnets.

These fail during `terraform plan`, before anything is touched, with the exact `error_message` string — much better than the opaque AWS API error you'd get if a mismatched subnet reached the `aws_lb` resource.

```hcl
locals {
  primary_az = one(distinct([for s in data.aws_subnet.app : s.availability_zone]))
}
```

`one(...)` returns the single element of a list, and *errors* if there isn't exactly one. Since this stack is single-AZ for compute by design (see `compute.tf`), this local doubles as an implicit assertion: if you ever passed `app_subnet_ids` spanning two AZs, this line itself would fail at plan time (surfacing the single-AZ assumption baked into `compute.tf` before you got a confusing downstream error).

**The one deliberate exception**, per the file's top comment: `nat_instance.tf` manages a single route in the private route table. That resource lives in a different file because it's optional (gated behind `nat_instance_enabled`), but it's worth remembering the promise this file makes is *"everything except that one route"*, not *"nothing, ever."*

---

## `security_groups.tf` — three empty groups, rules added elsewhere

```hcl
resource "aws_security_group" "alb" { ... }
resource "aws_security_group" "ui"  { ... }
resource "aws_security_group" "api" { ... }
```

Three groups, each with just a `name`, `description`, `vpc_id`, and a tag — no inline `ingress`/`egress` blocks. This is deliberate, explained in the file's header comment: inline rules on `ui` and `api` would need to reference each other's group IDs, which Terraform can't resolve if both are declared inline in the same `apply` (a dependency cycle). Splitting rules into separate `aws_vpc_security_group_ingress_rule` / `_egress_rule` resources breaks the cycle, since each rule resource depends on two *already-created* groups rather than being nested inside one of them.

Each group also has:
```hcl
lifecycle {
  create_before_destroy = true
}
```
This means if a group ever needs replacing (e.g., you rename it), Terraform creates the new one first and only destroys the old one after everything referencing it has moved over — avoiding a window where dependent resources point at a security group that no longer exists.

**ALB rules** (the only group allowed inbound from the internet):
- `alb_https` — `count = var.certificate_arn == "" ? 0 : 1`. Only exists once HTTPS is actually turned on (see `acm.tf`'s `local.has_https`, which is really what should gate this — but note this file checks `var.certificate_arn` directly rather than `local.has_https`; both currently evaluate the same way since `has_https` is defined as `var.certificate_arn != ""`, just be aware this file predates `acm.tf` and hasn't been refactored to reference the local directly).
- `alb_http` — always exists. Its `description` changes based on whether HTTPS is on (`"HTTP from the internet"` vs `"...redirected to HTTPS"`) purely for readability in the AWS console — functionally identical either way.
- `alb_to_ui` / `alb_to_api` — **egress** rules from the ALB's group, each referencing the *destination* group (`referenced_security_group_id = aws_security_group.ui.id`). This is the AWS mechanism that makes "reference a security group instead of an IP" work: the rule says "I can send traffic to anything with security group X," and the matching *ingress* rule on the other side says "I accept traffic from anything with security group Y." Both sides have to agree.

**UI tier:**
- `ui_from_alb` — ingress, references `aws_security_group.alb.id` as the source. Only the ALB can reach the UI instances.
- `ui_all` — egress, wide open (`cidr_ipv4 = "0.0.0.0/0"`, `ip_protocol = "-1"` meaning all protocols). The comment explains why: instances need this for package installs and reaching SSM. Tightened later if needed via VPC endpoints.

**API tier:**
- `api_from_alb` — ingress from the ALB (for the `/api/*` path-routed traffic and health checks).
- `api_from_ui` — ingress from the UI tier's own group. This is what lets the UI make server-side calls to the API.
- `api_all` — egress, same as UI's.

**No port 22, anywhere** — called out explicitly in the closing comment. Shell access is SSM Session Manager only (the IAM role granting that lives in `compute.tf`, the actual teammate access grant lives in `access.tf`).

---

## `compute.tf` — the two EC2 instance types this stack runs, and the IAM role they share

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}
```
Always resolves to the newest Amazon Linux 2023 AMI at `apply` time — meaning a fresh `terraform apply` months from now could pick up a newer AMI than the one currently running, which (combined with `user_data_replace_on_change`, below) would trigger an instance replacement you didn't explicitly ask for. Worth knowing if an unexpected replacement ever shows up in a `plan`.

**IAM role, shared by every EC2 instance in this stack** (ui, api, and — once `nat_instance.tf` is in play — the NAT instance too):
```hcl
resource "aws_iam_role" "instance" { ... }
resource "aws_iam_role_policy_attachment" "ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
resource "aws_iam_instance_profile" "instance" { ... }
```
`AmazonSSMManagedInstanceCore` is *the* policy that makes `aws ssm start-session --target <id>` work — it's what replaces a bastion host and an open port 22 throughout this entire stack. `CloudWatchAgentServerPolicy` is attached but nothing in `user_data` currently installs/configures the CloudWatch agent — it's provisioned for future use, not active today.

**`aws_instance.ui`** — the interesting part is the templated `user_data`:
```hcl
user_data = <<-EOT
  #!/bin/bash
  set -euxo pipefail
  dnf install -y docker
  systemctl enable --now docker

  %{if var.ui_image != ""~}
  docker pull ${var.ui_image}
  docker run -d --name app --restart=always \
    -p ${var.ui_port}:${var.ui_container_port} \
    ${var.ui_image}
  %{else~}
  dnf install -y python3
  mkdir -p /opt/placeholder && cd /opt/placeholder
  echo "ui ok" > index.html
  nohup python3 -m http.server ${var.ui_port} >/dev/null 2>&1 &
  %{endif~}
EOT
```
The `%{if ... }` / `%{else~}` / `%{endif~}` syntax is Terraform's *template directive* — it's evaluated when Terraform renders the string, not at instance boot time. So the *rendered* `user_data` that actually reaches the instance contains only one branch's worth of shell script; the instance itself has no idea the `if` ever existed. The `~` trims surrounding whitespace/newlines so the rendered script doesn't end up with ragged blank lines. This is exactly the mechanism that currently runs the real `fleet-agent-ai` image (because `ui_image` is set in `terraform.tfvars`) instead of the `"ui ok"` placeholder text.

```hcl
user_data_replace_on_change = true
```
Any change to the *rendered* `user_data` string — a new `ui_image` tag, a different `ui_port` — forces Terraform to destroy and recreate the instance (not an in-place update; AWS doesn't support changing an instance's user data after launch). This is exactly what happened earlier when `ui_image` was set for the first time: the instance was replaced, briefly taking the target group unhealthy until the new instance passed its health check. Comment this line out if you'd rather deploy app changes out-of-band and never let Terraform touch a running box.

```hcl
resource "aws_lb_target_group_attachment" "ui" {
  count             = var.ui_instance_count
  target_group_arn  = aws_lb_target_group.ui.arn
  target_id         = aws_instance.ui[count.index].id
  port              = var.ui_port
}
```
Registers each UI instance into the UI target group (defined in `alb.tf`). Note `port = var.ui_port` — this is the **host** port the ALB connects to, which is why `docker run` above maps `-p ${var.ui_port}:${var.ui_container_port}` (host:container). The ALB never needs to know the container's internal port.

**`aws_instance.api`** — nearly identical structure, with two differences:
1. `user_data` writes `/etc/app.env` *before* installing Docker:
   ```hcl
   cat > /etc/app.env <<'ENVEOF'
   DB_HOST=${var.existing_db_host}
   DB_PORT=${var.db_port}
   DB_SECRET_ARN=${var.existing_db_secret_arn}
   ENVEOF
   ```
   The comment above this in the actual file explains the reasoning: the database *password* is deliberately never written here. Only the secret's *ARN* is, and the running container is expected to fetch the actual credential from Secrets Manager at runtime using the instance's IAM role (see `database.tf`'s conditional `aws_iam_role_policy.db_secret_read`). If the password were baked into `user_data` directly, it would be readable in plaintext by anything on the instance via the EC2 instance metadata service (IMDS) — a much larger exposure than a scoped Secrets Manager read permission.
2. The `docker run` command adds `--env-file /etc/app.env`, which is how that file actually reaches the container process.

Both instance resources also set:
```hcl
metadata_options {
  http_tokens                 = "required"
  http_endpoint               = "enabled"
  http_put_response_hop_limit = 2
}
```
`http_tokens = "required"` forces IMDSv2 (token-based metadata requests) and disables the older IMDSv1, which is the standard hardening step against SSRF-style attacks that trick an application into reading instance credentials off the metadata endpoint.

Both also set `root_block_device { encrypted = true, delete_on_termination = true, volume_type = "gp3" }` — encrypted-at-rest storage that's cleaned up automatically when the instance is terminated (no orphaned volumes to notice and pay for later, which is exactly the kind of thing that turned up as drift on the *untracked* instances found earlier in this environment).

---

## `alb.tf` — the load balancer, its target groups, and its listeners

```hcl
locals {
  default_target_group_arn = var.alb_default_target == "api" ? aws_lb_target_group.api.arn : aws_lb_target_group.ui.arn
  create_api_path_rule      = var.alb_default_target != "api"
}
```
This is the entire behavior of `alb_default_target` distilled into two locals. If it's `"ui"` (the current setting), the default target is the UI group, *and* a path rule gets created to send `/api/*` to the API group (`create_api_path_rule = true`). If it's `"api"`, the default already *is* the API, so a redundant "send /api/* to API" rule would be a no-op — skipped.

```hcl
resource "aws_lb" "main" {
  load_balancer_type = "application"
  internal            = false
  security_groups     = [aws_security_group.alb.id]
  subnets             = var.alb_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = var.environment == "prod"
}
```
`drop_invalid_header_fields = true` is an AWS-recommended hardening default (silently drops malformed HTTP headers rather than passing them through). `enable_deletion_protection = var.environment == "prod"` means this stack protects the ALB from accidental `terraform destroy` only in a prod environment — in `dev` (the current setting), destroy works normally.

**Target groups** — `ui` (port `var.ui_port`, health check `var.ui_health_check_path`, matcher `"200-399"`) and `api` (port `var.api_port`, health check `var.api_health_check_path`, matcher `"200"` — stricter, exact match only). Both have `lifecycle { create_before_destroy = true }` for the same reason the security groups do: replacing a target group shouldn't create a window with zero valid targets.

**Listeners** — this is the part that changed most during this session's HTTPS work:
```hcl
resource "aws_lb_listener" "http" {
  port     = 80
  protocol = "HTTP"

  dynamic "default_action" {
    for_each = local.has_https ? [1] : []
    content {
      type = "redirect"
      redirect { port = "443", protocol = "HTTPS", status_code = "HTTP_301" }
    }
  }

  dynamic "default_action" {
    for_each = local.has_https ? [] : [1]
    content {
      type             = "forward"
      target_group_arn = local.default_target_group_arn
    }
  }
}
```
A `dynamic` block generates zero or more nested blocks from a list — here, each `dynamic "default_action"` produces exactly one `default_action` if its `for_each` list has one element (`[1]`), or zero if the list is empty (`[]`). Since `local.has_https` is a boolean, exactly one of these two dynamic blocks ever actually produces content: HTTPS on → redirect to 443; HTTPS off → forward straight to the app. This pattern (a boolean toggling between two mutually-exclusive `dynamic` blocks) shows up because `aws_lb_listener` only accepts *one* `default_action`, and Terraform doesn't have a native `if/else` for nested blocks — this is the idiomatic workaround.

```hcl
resource "aws_lb_listener" "https" {
  count           = local.has_https ? 1 : 0
  port            = 443
  protocol        = "HTTPS"
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = local.certificate_arn
  default_action { type = "forward", target_group_arn = local.default_target_group_arn }
}
```
`count` on a whole resource (rather than `dynamic` on a nested block) is the pattern for "does this resource exist at all." `local.has_https` — defined in `acm.tf` — decides whether the 443 listener exists at all. Critically, this `count` expression must depend only on values known at *plan* time (like `var.certificate_arn`), never on an attribute of a resource still being created in the same apply — see `acm.tf` below for why that distinction caused a real bug during setup.

```hcl
resource "aws_lb_listener_rule" "api" {
  count        = local.create_api_path_rule ? 1 : 0
  listener_arn = local.has_https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 100
  condition { path_pattern { values = var.api_path_patterns } }
  action     { type = "forward", target_group_arn = aws_lb_target_group.api.arn }
}
```
This is the `/api/*` routing rule, attached to whichever listener is actually active (HTTPS if on, plain HTTP otherwise) — again via a ternary rather than a `dynamic` block, since there's exactly one listener ARN needed, not zero-or-more nested blocks.

---

## `acm.tf` — the HTTPS certificate, and the trickiest bit of conditional logic in this repo

```hcl
resource "aws_acm_certificate" "main" {
  count             = var.domain_name == "" ? 0 : 1
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

locals {
  certificate_arn = var.certificate_arn
  has_https       = var.certificate_arn != ""
}
```

The file header comment explains the "why" in full, but the short version, and the bug it fixes: **AWS refuses to attach a certificate to an ALB listener until that certificate's status is `ISSUED`.** A newly-requested certificate starts in `PENDING_VALIDATION` and only becomes `ISSUED` once DNS validation completes — which, for a domain hosted outside Route 53 (this stack's domain is on Cloudflare), requires a human to manually add a CNAME record. Terraform has no way to wait for that to happen automatically within a single `apply`.

The first version of this file got this wrong: it computed `local.has_https` from *whether the certificate resource existed*, meaning the HTTPS listener in `alb.tf` would try to attach a certificate the moment it was requested — long before it was actually validated. That `apply` failed outright with an AWS API error (`UnsupportedCertificate`), and even the fallback state (HTTP listener) briefly ended up in an invalid combination (a `redirect` action with a leftover `target_group_arn` set).

The fix, reflected in the code above: `local.has_https` is derived from `var.certificate_arn` — an *explicit, plan-time-known* input — never from the ACM resource's own (unknown-until-apply) `.arn` or `.status`. This means turning on HTTPS is genuinely a **two-step, two-`apply`** process:
1. Set `domain_name`, leave `certificate_arn` empty, `apply`. This only requests the certificate (`count = 1` on `aws_acm_certificate.main`) — `has_https` is still `false`, so nothing in `alb.tf` changes.
2. Add the DNS validation record (from `terraform output acm_validation_record`) wherever your DNS is hosted. Once ACM shows `ISSUED` (`terraform output acm_certificate_status`), copy the ARN into `certificate_arn` and `apply` again — *now* `has_https` flips to `true`, and that's the apply that actually creates the HTTPS listener and turns on the HTTP→HTTPS redirect.

`domain_name` alone never turns on HTTPS by itself — that's the whole point of separating the two variables.

---

## `database.tf` — one rule on a security group this stack doesn't own

```hcl
resource "aws_vpc_security_group_ingress_rule" "existing_db_from_api" {
  security_group_id            = var.existing_db_security_group_id
  description                  = "${local.name} API tier"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}
```
This is the concrete example of the pattern described at the top of this doc: `security_group_id` points at a group Terraform never created (`var.existing_db_security_group_id`, just a string the user supplies), but Terraform still fully manages this *one rule* on it. Every other rule already on that security group — and the group itself — is left completely alone. The file's own header comment flags the one sharp edge: running `terraform destroy` *will* remove this specific rule (since Terraform owns it), even though it never created the group.

```hcl
data "aws_iam_policy_document" "db_secret_read" {
  count = var.existing_db_secret_arn == "" ? 0 : 1
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.existing_db_secret_arn]
  }
}

resource "aws_iam_role_policy" "db_secret_read" {
  count  = var.existing_db_secret_arn == "" ? 0 : 1
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.db_secret_read[0].json
}
```
Both gated on the same condition, both entirely skipped if `existing_db_secret_arn` is left empty. When it *is* set, this grants the shared instance IAM role (from `compute.tf`) read-only access to exactly that one secret — nothing broader. This is the other half of the "password never touches `user_data`" design described under `compute.tf`.

---

## `access.tf` — teammate shell access via SSM, not SSH

```hcl
variable "ssm_user_names" {
  type    = list(string)
  default = []
}

data "aws_caller_identity" "current" {}
```
`aws_caller_identity` is a data source with no arguments — it just returns facts about whoever is currently authenticated (their AWS account ID, mainly), used below to build ARNs without hardcoding the account number.

```hcl
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
  ...
}
```
This is the interesting design decision, worth understanding fully: the `resources` ARN pattern is `instance/*` — matching *every* EC2 instance in the account, not just `ui`/`api` specifically. The actual scoping happens in the two `condition` blocks instead, which restrict `ssm:StartSession` to only instances tagged `Project = agentic-asset` *and* `ManagedBy = terraform` — tags every resource in this stack gets automatically from `versions.tf`'s `default_tags` block. The reason for tag-based rather than instance-ID-based scoping: this stack replaces `ui`/`api` instances on every `user_data` change (see `compute.tf`), which would mean a new instance ID every time — an ID-based policy would silently stop covering the new instance until someone remembered to update it. A tag-based policy just keeps working.

This also means the policy is provably scoped to *only* this stack's own instances — it was checked against the untracked EC2 instances found elsewhere in the account during this session, and confirmed none of them carried these tags, so this policy could never have accidentally granted access to them.

```hcl
statement {
  sid       = "ManageOwnSessions"
  actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
  resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:session/$${aws:username}-*"]
}
```
Note `$${aws:username}` — the doubled `$` is Terraform's escape for a literal `${...}` in the output string. Without the extra `$`, Terraform would try to interpolate `aws:username` as one of *its own* variables (and fail, since no such thing exists) instead of leaving it as the literal IAM policy variable AWS itself resolves at request time — the current caller's own username. This scopes `TerminateSession`/`ResumeSession` to sessions the caller started themselves, not anyone else's.

```hcl
statement {
  sid     = "SessionManagerReadOnly"
  actions = ["ssm:DescribeSessions", "ssm:GetConnectionStatus", "ssm:DescribeInstanceInformation", "ec2:DescribeInstances"]
  resources = ["*"]
}
```
Broader read-only permissions needed for the AWS CLI / console to function normally (listing instances, checking session status) — none of these grant any ability to *start* a session on anything, that's still gated by the first statement's tag condition.

```hcl
resource "aws_iam_policy" "ssm_session_access" { policy = data.aws_iam_policy_document.ssm_session_access.json }
resource "aws_iam_group" "ssm_users" { }
resource "aws_iam_group_policy_attachment" "ssm_session_access" { }

resource "aws_iam_group_membership" "ssm_users" {
  group = aws_iam_group.ssm_users.name
  users = var.ssm_user_names
}
```
`aws_iam_group_membership` is **authoritative for this one group's member list** — every `apply`, Terraform sets the group's membership to exactly `var.ssm_user_names`, adding or removing users as needed to match. It deliberately does *not* use `aws_iam_user_group_membership` (the per-user variant), because that resource type is authoritative for *all* of a given user's group memberships across every group — using it here would risk silently kicking a user out of some unrelated group they belong to, the first time this stack's state didn't happen to list it. The group-scoped resource only ever touches this one group.

`var.ssm_user_names` itself is set in `access.auto.tfvars` (see the tfvars section below) rather than the gitignored `terraform.tfvars`, specifically so that granting or revoking access is a visible, reviewable one-line change in git history — not a silent local edit only the person running `apply` can see.

---

## `nat_instance.tf` — an optional, cheaper NAT, with a two-flag safety switch

Already covered in detail in `README.md`'s "Replacing the NAT Gateway" section and in the file's own header comment, but the parts worth calling out here:

```hcl
resource "aws_route" "private_egress" {
  count = var.nat_instance_enabled ? 1 : 0

  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id       = var.use_nat_instance_for_egress ? null : var.existing_nat_gateway_id
  network_interface_id = var.use_nat_instance_for_egress ? aws_instance.nat[0].primary_network_interface_id : null
}
```
Two things worth understanding here that weren't obvious while building this:
1. **This resource is gated on `nat_instance_enabled`, not unconditional.** An earlier version had no `count` at all, meaning *every* user of this Terraform template — even ones who never touch the NAT instance feature — would suddenly have Terraform asserting ownership of a route it had no business touching. Gating it behind the same flag that creates the instance keeps the "we don't touch your network by default" promise intact for anyone who doesn't opt in.
2. **`network_interface_id`, not `instance_id`.** The first draft used `instance_id = aws_instance.nat[0].id` directly (which is what most NAT-instance tutorials show) — `terraform validate` rejected it outright: current versions of the AWS provider treat `aws_route.instance_id` as a read-only, computed attribute, not something you can set. The fix is to route to the instance's *primary network interface* directly instead.

Also note this route can't simply be *created* the normal way if a `0.0.0.0/0` route already exists in that route table (it will, since the pre-existing NAT Gateway already has one) — AWS returns `RouteAlreadyExists`. The first `apply` after adding this resource has to be preceded by a one-time `terraform import 'aws_route.private_egress[0]' '<route-table-id>_0.0.0.0/0'`, which teaches Terraform's state about the already-existing route without changing anything in AWS. After that one-time import, normal `apply` behavior takes over.

```hcl
resource "aws_instance" "nat" {
  count              = var.nat_instance_enabled ? 1 : 0
  source_dest_check  = false
  ...
}
```
`source_dest_check = false` is the single setting that makes this a NAT instance instead of an ordinary EC2 box: by default, AWS drops any packet an instance sends/receives that isn't addressed directly to itself — the entire point of NAT is forwarding packets addressed to *other* hosts, so this check has to be explicitly turned off.

```hcl
IFACE=$(ip -o -4 route show to default | awk '{print $5}')
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
```
The interface name is detected at boot rather than hardcoded (an early draft assumed `eth0`) — Amazon Linux 2023 on this instance type actually names its primary interface `ens5`. Hardcoding the wrong interface name would have silently produced a NAT instance that passes every internal health check while forwarding zero packets.

Two variables (`nat_instance_enabled`, `use_nat_instance_for_egress`) rather than one is the safety mechanism: the first creates the instance without touching live traffic; the second — applied only after manually verifying the instance's `iptables`/`sysctl` config over SSM — is what actually redirects the route. Flipping the second flag back to `false` and re-applying is a complete, instance-independent rollback, since it only touches the route table entry, not anything on the instance itself.

---

## `outputs.tf` — everything you'd otherwise have to look up in the console

Each `output` block is a value Terraform prints after `apply` and makes available via `terraform output <name>`. A few worth understanding rather than skimming:

```hcl
output "app_url" {
  value = local.has_https ? "https://${aws_lb.main.dns_name}" : "http://${aws_lb.main.dns_name}"
}
```
Reflects the `acm.tf`/`alb.tf` HTTPS logic — this output is only `https://` once HTTPS is genuinely live, not just requested.

```hcl
output "acm_certificate_status" {
  value = var.domain_name == "" || var.certificate_arn != "" ? null : aws_acm_certificate.main[0].status
}
```
Returns `null` (rather than erroring) in the two cases where `aws_acm_certificate.main[0]` wouldn't exist to read a `.status` from: no `domain_name` set at all, or `certificate_arn` already set explicitly (meaning this stack isn't the one managing the certificate's lifecycle). This null-guarding pattern — checking the same condition that gates a resource's `count` before referencing an indexed attribute of it — shows up throughout this repo (also in `acm_validation_record`, `nat_instance_id`, `nat_instance_public_ip`) specifically to avoid an "index out of range" error when the underlying resource simply doesn't exist in the current configuration.

```hcl
output "database_access" {
  value = "Ingress on port ${var.db_port} added to ${var.existing_db_security_group_id}, source ${aws_security_group.api.id}."
}
```
Not a resource attribute at all — just a human-readable sentence, useful because `database.tf`'s rule is easy to forget exists since it lives on a security group this stack doesn't otherwise show you.

```hcl
output "instance_ids" {
  value = { ui = aws_instance.ui[*].id, api = aws_instance.api[*].id }
}
```
The `[*]` splat operator returns a list of every instance's `.id` in the `count`-based resource — this stack currently runs one of each, but this output stays correct if `ui_instance_count`/`api_instance_count` are ever raised.

---

## The `.tfvars` files — three of them, each with a different job

- **`terraform.tfvars`** — the real values for *this* deployment (VPC ID, subnet IDs, image tags, the actual domain name, actual certificate ARN, NAT instance route table ID). Gitignored (`*.tfvars` in `.gitignore`), because it's specific to this one AWS account and, in the general case, could contain sensitive infrastructure identifiers. This is the file `terraform apply` actually reads by default.
- **`terraform.tfvars.example`** — a committed template with placeholder values (`vpc-XXXXXXXXXXXXXXXXX`) and extensive inline comments explaining each section, meant to be copied to `terraform.tfvars` and filled in. This is what makes the repo usable by someone who isn't this specific AWS account.
- **`access.auto.tfvars`** — committed, holds exactly one variable: `ssm_user_names`. Any file matching `*.auto.tfvars` is loaded automatically by Terraform without needing `-var-file` on the command line — same mechanism as `terraform.tfvars`, just a different, more specific filename. It's split out from the gitignored `terraform.tfvars` specifically so that *who has shell access* is a reviewable, git-tracked fact, not a local-only setting.

`.gitignore` has to special-case both non-default `.tfvars` files back in, since its blanket `*.tfvars` rule would otherwise exclude them too:
```
*.tfvars
!terraform.tfvars.example
!access.auto.tfvars
```

---

## Putting it together: what actually happens on `terraform apply`

1. Terraform loads every `.tf` file in the directory (order doesn't matter — see below) plus `terraform.tfvars` and every `*.auto.tfvars` file, and builds one dependency graph across all of them.
2. `network.tf`'s `data` blocks resolve first (nothing else can proceed without knowing the VPC/subnet details), then its `precondition` checks run — a bad `vpc_id` or single-AZ `alb_subnet_ids` stops here, before touching AWS.
3. `security_groups.tf`'s three empty groups get created (or confirmed to exist), since almost everything else references them.
4. `compute.tf`'s IAM role/instance profile, `alb.tf`'s ALB/target groups, and `acm.tf`'s certificate (if requested) can all proceed in parallel — Terraform parallelizes anything that isn't blocked by a dependency.
5. `aws_instance.ui`/`aws_instance.api` wait on the security groups, the IAM instance profile, and (if `ui_image`/`api_image` changed) get replaced rather than updated.
6. `database.tf`'s security group rule and `access.tf`'s IAM group/policy have no dependency on each other and apply independently.
7. `nat_instance.tf`'s resources only participate at all if `nat_instance_enabled = true`; the route itself only changes target if `use_nat_instance_for_egress` also flips.
8. `outputs.tf` values print at the end, once everything they reference has a known value.

**Why file order doesn't matter:** Terraform doesn't execute files top-to-bottom or in alphabetical order — it parses every file into one merged configuration, then walks the graph of `resource`/`data`/`local` references to figure out what depends on what, and parallelizes anything that doesn't share a dependency. `nat_instance.tf` referencing `data.aws_ami.al2023` (defined in `compute.tf`) or `local.name` (defined in `network.tf`) works exactly the same as if all three were in one giant file — the split into multiple files is purely for human readability, grouping resources by what they're *for* (network, compute, load balancing, access control) rather than by any execution order.
