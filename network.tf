# This stack creates no network. It deploys into the VPC your database
# already lives in, which is why there is no peering, no CIDR overlap risk,
# and why security groups can reference each other directly.
#
# Everything here is a lookup. Terraform will not modify your VPC, subnets,
# or route tables, and `terraform destroy` will not touch them — with one
# deliberate exception: nat_instance.tf manages a single route in the
# private route table (0.0.0.0/0), toggled between the pre-existing NAT
# Gateway and an optional cheaper NAT instance. Same pattern as database.tf
# mutating one rule on a security group it doesn't own, without taking
# ownership of the whole resource.

locals {
  name = "${var.project}-${var.environment}"
}

data "aws_vpc" "main" {
  id = var.vpc_id
}

# ---------------------------------------------------------------------------
# ALB subnets: must be public, must span two availability zones.
#
# The two-AZ requirement is an AWS constraint on Application Load Balancers,
# not a preference. Compute still lands in a single AZ.
# ---------------------------------------------------------------------------

data "aws_subnet" "alb" {
  for_each = toset(var.alb_subnet_ids)
  id       = each.value
}

# ---------------------------------------------------------------------------
# App subnets: where the instances run. Private, with a route to a NAT
# gateway or to SSM VPC endpoints.
# ---------------------------------------------------------------------------

data "aws_subnet" "app" {
  for_each = toset(var.app_subnet_ids)
  id       = each.value
}

# ---------------------------------------------------------------------------
# Preconditions
#
# These fail at plan time with a readable message rather than surfacing as an
# opaque API error partway through an apply.
# ---------------------------------------------------------------------------

resource "terraform_data" "network_checks" {
  lifecycle {
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.alb : s.availability_zone])) >= 2
      error_message = "alb_subnet_ids must cover at least two availability zones. AWS rejects an ALB placed in a single AZ."
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

locals {
  # AZ the instances run in. With one app subnet this is the only one.
  primary_az = one(distinct([for s in data.aws_subnet.app : s.availability_zone]))
}
