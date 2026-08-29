# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terraform for a two-tier app (UI + API) behind a single ALB, deployed into an **existing** VPC alongside an **existing** database. This stack creates no VPC, no NAT gateway, no database — it plugs into infrastructure that already exists via IDs passed in `terraform.tfvars`. See `README.md` for the full narrative (deploy steps, HTTPS setup, NAT-instance cutover, troubleshooting) — it's worth reading in full before making network or cost-related changes.

## Commands

```bash
terraform init
terraform fmt -check -diff      # this repo is fmt-clean; run before committing .tf changes
terraform validate
terraform plan
terraform apply
```

There is no test suite, linter config, or CI pipeline defined in this repo (the two GitHub Actions workflows referenced in `ci_deploy.tf` live in the *app* repos, not here). `terraform validate` + `terraform plan` is the closest thing to a check before applying.

Useful runtime lookups:
```bash
terraform output -raw app_url
terraform output -json instance_ids          # {ui: [...], api: [...]}
aws ssm start-session --target <instance-id> # shell access — see "No SSH" below
```

## Architecture

**File-by-file map**: `docs/terraform-guide.md` has a full walkthrough of every `.tf` file if you need it, and `docs/architecture.html` is a live diagram of the deployed AWS architecture. The short version:

- `network.tf` — reads the existing VPC/subnets via data sources. Deliberately touches nothing it doesn't own. `nat_instance.tf` is the one narrow exception (see below).
- `security_groups.tf` — three new SGs (`alb`, `ui`, `api`) plus one ingress rule bolted onto the *existing* DB security group.
- `compute.tf` — plain `aws_instance` resources for `ui` and `api` tiers (no ASG — see below), IAM instance role with `AmazonSSMManagedInstanceCore`.
- `alb.tf` — ALB, two target groups, listener rules (`/api/*` → api tier, priority 100, everything else → `alb_default_target`).
- `acm.tf` — optional cert request when `domain_name` is set instead of `certificate_arn`.
- `database.tf` — no DB resources; just the security-group rule granting `api` ingress to the existing DB.
- `access.tf` — human SSM access, IAM group scoped by resource tag (`Project` + `ManagedBy=terraform`), membership driven by `ssm_user_names`.
- `ci_deploy.tf` — per-tier IAM users for GitHub Actions to redeploy via `ssm:SendCommand` (not SSH). Scoped further by `Tier` tag so the UI repo's CI can't touch the API instance and vice versa.
- `nat_instance.tf` — optional cheaper NAT alternative (~$3.50/mo vs ~$66/mo), off by default (`nat_instance_enabled`), toggled onto the live route table by `use_nat_instance_for_egress`. Reversible cutover — see README for the 4-step procedure.

### No SSH, anywhere

There is no port 22 rule in this stack, on purpose. All shell access — human or CI — goes through **SSM Session Manager / Run Command**, scoped by IAM to instances carrying specific tags (`Project`, `ManagedBy=terraform`, and for CI, `Tier`). This is the load-bearing security model of the repo; don't add a `key_name` or port 22 ingress rule as a shortcut without understanding why it was avoided (see the comment block at the top of `ci_deploy.tf` for the history of why the old SSH-via-bastion path was replaced).

### Instance bootstrap and app config

Both tiers boot via `user_data` in `compute.tf` (`dnf install docker`, pull `var.{ui,api}_image`, `docker run` on the mapped port). Because `user_data_replace_on_change = true`, **any edit to a `user_data` block replaces the instance** — with `ui_instance_count`/`api_instance_count` typically at 1, that's real downtime, not a rolling update.

The API instance additionally writes `/etc/app.env` from Terraform variables (DB connection info, `GROQ_API_KEY`, `SECRET_KEY`, JWT settings, etc.) before the container starts, and runs the container with `--env-file /etc/app.env`. Two different exposure levels are deliberately in play here:

- The **DB password** is kept out of `user_data` entirely — only `DB_SECRET_ARN` is written, and the app fetches the actual secret from Secrets Manager at runtime using the instance role. This avoids the password sitting in `user_data` (readable via IMDS) or in Terraform state.
- Other backend secrets (`GROQ_API_KEY`, `SECRET_KEY`) are simpler `sensitive = true` Terraform variables interpolated directly into the `app.env` heredoc — pragmatic, but they **do** land in `user_data`/state, unlike the DB password. If this stops being acceptable, migrate them to the same Secrets-Manager-ARN-plus-runtime-fetch pattern.

Manually editing `/etc/app.env` on a running instance (e.g. via SSM session) is a valid quick fix, but it's out-of-band — the next `terraform apply` that touches `user_data` will overwrite it. To persist a value, add it as a Terraform variable and set it in `terraform.tfvars`.

### Secrets and tfvars

`terraform.tfvars` and `access.auto.tfvars` are gitignored (`*.tfvars` except the `.example` file) — that's where real values (image tags, DB host, API keys) live. Never commit real secrets into `.tf` files themselves; add a `variable` block with `sensitive = true` where appropriate and set the value in the local tfvars file.

### Single AZ, no autoscaling

Everything except the ALB runs in one AZ (`app_subnet_ids` takes a single subnet). The ALB is the one mandatory multi-AZ exception — AWS requires ≥2 AZs for ALB subnets, so `alb_subnet_ids` always needs two even though the second holds nothing. There's no autoscaling group: a crashed instance stays down until someone runs `terraform apply` or restarts it manually, and scaling means editing `ui_instance_count`/`api_instance_count` by hand.
