variable "project" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "fleet-agent"
}

variable "environment" {
  description = "Environment name, e.g. dev, staging, prod."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# Existing network
#
# This stack creates no VPC or subnets. It deploys into the VPC your database
# already lives in.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC to deploy into. Must be the one your database is in."
  type        = string

  validation {
    condition     = can(regex("^vpc-", var.vpc_id))
    error_message = "vpc_id must look like vpc-0123456789abcdef0."
  }
}

variable "alb_subnet_ids" {
  description = "Public subnets for the load balancer. Must span at least two AZs \u2014 AWS rejects a single-AZ ALB. These need a route to an internet gateway."
  type        = list(string)

  validation {
    condition     = length(var.alb_subnet_ids) >= 2
    error_message = "An ALB requires at least two subnets in different availability zones."
  }
}

variable "app_subnet_ids" {
  description = "Private subnets for the UI and API instances. Pass a single subnet ID for single-AZ. These need outbound internet via NAT, or SSM VPC endpoints, or the SSM agent will not register."
  type        = list(string)

  validation {
    condition     = length(var.app_subnet_ids) >= 1
    error_message = "At least one app subnet is required."
  }
}

# ---------------------------------------------------------------------------
# Application ports
# ---------------------------------------------------------------------------

variable "ui_port" {
  description = "Port the UI server listens on."
  type        = number
  default     = 3000
}

variable "api_port" {
  description = "Port the backend API listens on."
  type        = number
  default     = 8080
}

variable "ui_health_check_path" {
  description = "Path the ALB polls on the UI target group. Must return 200."
  type        = string
  default     = "/"
}

variable "api_health_check_path" {
  description = "Path the ALB polls on the API target group. Must return 200."
  type        = string
  default     = "/api/health"
}

variable "api_path_patterns" {
  description = "Request paths routed to the backend instead of the UI."
  type        = list(string)
  default     = ["/api/*"]
}

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS. Leave empty to run HTTP-only (fine for a first deploy, not for production). Must be in the same region as the ALB."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "ui_instance_type" {
  type    = string
  default = "t3.small"
}

variable "api_instance_type" {
  type    = string
  default = "t3.small"
}

variable "ui_instance_count" {
  description = "Number of UI instances. All land in the single app subnet."
  type        = number
  default     = 1
}

variable "api_instance_count" {
  description = "Number of API instances. All land in the single app subnet."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Existing database
#
# This stack does not create a database. These variables describe the one you
# already have so the API tier can reach it.
# ---------------------------------------------------------------------------

variable "db_port" {
  description = "Port your database listens on. 5432 for Postgres, 3306 for MySQL."
  type        = number
  default     = 5432
}

variable "existing_db_security_group_id" {
  description = "Security group attached to your existing database. Terraform adds one ingress rule to it allowing the API tier on db_port."
  type        = string

  validation {
    condition     = can(regex("^sg-", var.existing_db_security_group_id))
    error_message = "existing_db_security_group_id must look like sg-0123456789abcdef0."
  }
}

variable "existing_db_host" {
  description = "Hostname or endpoint of your database. Passed to the app tier as an environment variable. Optional."
  type        = string
  default     = ""
}

variable "existing_db_secret_arn" {
  description = "Secrets Manager ARN holding the database credentials. If set, the API instance role is granted read access to it. Leave empty to manage credentials another way."
  type        = string
  default     = ""
}

variable "alb_default_target" {
  description = "Which tier receives traffic matching no listener rule."
  type        = string
  default     = "ui"

  validation {
    condition     = contains(["ui", "api"], var.alb_default_target)
    error_message = "alb_default_target must be either \"ui\" or \"api\"."
  }
}

# ---------------------------------------------------------------------------
# Container images
# ---------------------------------------------------------------------------

variable "api_image" {
  description = "Container image for the backend. Leave empty to run a placeholder that only answers health checks."
  type        = string
  default     = ""
}

variable "api_container_port" {
  description = "Port the container listens on internally. Mapped to api_port on the host. FastAPI/uvicorn commonly uses 8000."
  type        = number
  default     = 8000
}

variable "ui_image" {
  description = "Container image for the frontend. Leave empty to run a placeholder."
  type        = string
  default     = ""
}

variable "ui_container_port" {
  description = "Port the UI container listens on internally."
  type        = number
  default     = 3000
}