# ---------------------------------------------------------------------------
# NAT instance, as a cheaper alternative to the pre-existing NAT Gateway.
#
# The NAT Gateway costs roughly $66/month regardless of how little traffic
# passes through it — the flat hourly charge dominates a low-traffic dev
# environment's bill. A small self-managed instance does the same job for
# ~$3.50/month, at the cost of losing AWS's managed multi-AZ failover.
# Acceptable here; this stack is already single-AZ everywhere except the ALB.
#
# Two flags drive a safe, staged rollout instead of one big cutover:
#
#   nat_instance_enabled        — does the instance/EIP/SG exist at all?
#   use_nat_instance_for_egress — which one does the live route point at?
#
# Bring the instance up first, verify it over SSM, only then flip the route.
# Flipping it back is a single-flag, single-apply rollback that doesn't
# depend on the instance being reachable — just on the route table, which
# always is.
# ---------------------------------------------------------------------------

variable "nat_instance_enabled" {
  description = "Create the NAT instance, its EIP, and its security group. Does not affect which one is actually routed to — see use_nat_instance_for_egress."
  type        = bool
  default     = false
}

variable "use_nat_instance_for_egress" {
  description = "false = private subnets route through the existing NAT Gateway (today's state). true = they route through the NAT instance instead. Only meaningful once nat_instance_enabled has been applied and the instance verified."
  type        = bool
  default     = false
}

variable "private_route_table_id" {
  description = "Route table holding the private subnets' 0.0.0.0/0 route. Required only if nat_instance_enabled is used."
  type        = string
  default     = ""
}

variable "existing_nat_gateway_id" {
  description = "The pre-existing NAT Gateway to fail back to when use_nat_instance_for_egress is false. Required only if nat_instance_enabled is used."
  type        = string
  default     = ""
}

variable "nat_instance_subnet_id" {
  description = "Public subnet for the NAT instance. Should match the AZ of app_subnet_ids to avoid cross-AZ data charges. Required only if nat_instance_enabled is used."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# The one route this stack manages in a route table it doesn't own — same
# pattern as database.tf mutating one rule on a security group it doesn't
# own, without taking ownership of the whole resource.
# ---------------------------------------------------------------------------

resource "aws_route" "private_egress" {
  count = var.nat_instance_enabled ? 1 : 0

  route_table_id         = var.private_route_table_id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id       = var.use_nat_instance_for_egress ? null : var.existing_nat_gateway_id
  network_interface_id = var.use_nat_instance_for_egress ? aws_instance.nat[0].primary_network_interface_id : null
}

resource "aws_security_group" "nat_instance" {
  name        = "${local.name}-nat-instance"
  description = "Allows the private subnets to route outbound traffic through the NAT instance."
  vpc_id      = var.vpc_id

  ingress {
    description = "All traffic from the private subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.11.0/24", "10.0.12.0/24"]
  }

  egress {
    description = "Outbound to the internet on behalf of the private subnets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-nat-instance" }
}

resource "aws_instance" "nat" {
  count = var.nat_instance_enabled ? 1 : 0

  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3a.nano"
  subnet_id              = var.nat_instance_subnet_id
  vpc_security_group_ids = [aws_security_group.nat_instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # The setting that makes this a NAT instance instead of a normal EC2 box.
  # Without it, the instance drops any packet not addressed to itself.
  source_dest_check = false

  monitoring = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-nat.conf
    sysctl -p /etc/sysctl.d/99-nat.conf

    dnf install -y iptables-services
    systemctl enable iptables

    IFACE=$(ip -o -4 route show to default | awk '{print $5}')

    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    iptables -A FORWARD -i "$IFACE" -o "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i "$IFACE" -o "$IFACE" -j ACCEPT

    service iptables save
  EOT

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-nat-instance"
  }
}

resource "aws_eip" "nat" {
  count = var.nat_instance_enabled ? 1 : 0

  instance = aws_instance.nat[0].id
  domain   = "vpc"

  tags = { Name = "${local.name}-nat-instance" }
}

output "nat_instance_id" {
  description = "SSM target for verifying the NAT instance before cutover: aws ssm start-session --target <this>"
  value       = var.nat_instance_enabled ? aws_instance.nat[0].id : null
}

output "nat_instance_public_ip" {
  value = var.nat_instance_enabled ? aws_eip.nat[0].public_ip : null
}
