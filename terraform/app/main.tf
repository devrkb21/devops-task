locals {
  name      = "${var.project}-${var.environment}"
  log_group = "/${var.project}/${var.environment}/app"
  registry  = split("/", data.aws_ecr_repository.app.repository_url)[0]
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Latest Amazon Linux 2023 AMI, published by AWS in SSM Parameter Store
# (insecure_value: the AMI ID is public, so it need not be hidden in plans).
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

data "aws_ecr_repository" "app" {
  name = var.ecr_repository_name
}

# ---------------------------------------------------------------------------
# Network: only the application port is open. There is no SSH (port 22) at all;
# administration and deployments go through AWS Systems Manager.
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = "${local.name}-app"
  description = "Allow inbound traffic to the application port only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "Application HTTP"
  cidr_ipv4         = each.value
  from_port         = var.app_port
  to_port           = var.app_port
  ip_protocol       = "tcp"
}

# Outbound HTTPS is needed for ECR, SSM, CloudWatch and OS packages. In production this
# could be narrowed further with VPC endpoints.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Outbound to AWS APIs and package repositories"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ---------------------------------------------------------------------------
# IAM: the instance role can pull this one image repository, write to this one log
# group and register with SSM. Nothing else. No static access keys exist anywhere.
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

resource "aws_iam_role" "app" {
  name               = "${local.name}-instance"
  description        = "EC2 instance role for ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# AWS-managed minimum for the SSM agent (Run Command, Session Manager).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this action does not support resource-level permissions
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [data.aws_ecr_repository.app.arn]
  }

  statement {
    sid = "WriteContainerLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "pull-image-and-write-logs"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-instance"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region    = var.aws_region
    environment   = var.environment
    log_group     = aws_cloudwatch_log_group.app.name
    app_port      = var.app_port
    registry      = local.registry
    initial_image = var.initial_image_tag == "" ? "" : "${data.aws_ecr_repository.app.repository_url}:${var.initial_image_tag}"
    deploy_script = file("${path.module}/templates/deploy-app.sh")
  })

  # IMDSv2 only. A hop limit of 1 means containers on the Docker bridge network cannot
  # reach the metadata service, so the app can never read the instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    # A newer AMI must not silently replace a running server on the next apply.
    # Patch by rebuilding deliberately (taint/replace) or with SSM Patch Manager.
    ignore_changes = [ami, user_data]
  }
}
