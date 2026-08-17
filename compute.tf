data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ---------------------------------------------------------------------------
# Instance role
#
# AmazonSSMManagedInstanceCore is what makes `aws ssm start-session` work.
# It replaces a bastion host and an open port 22, and every session is logged
# in CloudTrail.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# UI instances
#
# Plain EC2, no autoscaling group. Consequences worth knowing:
#   - a failed instance stays failed until you fix it or re-apply
#   - a config change to user_data replaces the instance, causing downtime
#   - scaling means editing ui_instance_count and applying
# ---------------------------------------------------------------------------

resource "aws_instance" "ui" {
  count = var.ui_instance_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ui_instance_type
  subnet_id              = var.app_subnet_ids[count.index % length(var.app_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.ui.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  monitoring = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Replace with your real bootstrap. The placeholder just answers health
  # checks so you can verify the network path before adding your own app as
  # a second variable.
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

  # Editing user_data triggers a replacement. Comment this out if you would
  # rather deploy app changes out of band and never have Terraform touch a
  # running instance.
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-ui-${count.index}"
    Tier = "ui"
  }
}

resource "aws_lb_target_group_attachment" "ui" {
  count = var.ui_instance_count

  target_group_arn = aws_lb_target_group.ui.arn
  target_id        = aws_instance.ui[count.index].id
  port             = var.ui_port
}

# ---------------------------------------------------------------------------
# API instances
# ---------------------------------------------------------------------------

resource "aws_instance" "api" {
  count = var.api_instance_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.api_instance_type
  subnet_id              = var.app_subnet_ids[count.index % length(var.app_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.api.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  monitoring = true

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    # Connection details for the existing database. The password is not here
    # on purpose: fetch it at runtime from Secrets Manager using the instance
    # role, so it never lands in user data (readable via IMDS) or in state.
    cat > /etc/app.env <<'ENVEOF'
    DB_HOST=${var.existing_db_host}
    DB_PORT=${var.db_port}
    DB_SECRET_ARN=${var.existing_db_secret_arn}
    ENVEOF

     dnf install -y docker
    systemctl enable --now docker

    %{if var.api_image != ""~}
    docker pull ${var.api_image}
    docker run -d --name app --restart=always \
      --env-file /etc/app.env \
      -p ${var.api_port}:${var.api_container_port} \
      ${var.api_image}
    %{else~}
    dnf install -y python3
    mkdir -p /opt/placeholder/api && cd /opt/placeholder
    echo '{"status":"ok"}' > health
    nohup python3 -m http.server ${var.api_port} >/dev/null 2>&1 &
    %{endif~}
  EOT

  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-api-${count.index}"
    Tier = "api"
  }
}

resource "aws_lb_target_group_attachment" "api" {
  count = var.api_instance_count

  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.api[count.index].id
  port             = var.api_port
}
