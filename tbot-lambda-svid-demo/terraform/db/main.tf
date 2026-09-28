# Postgres host for the tbot SVID demo.
#
# This is a separate root module on purpose: the main module needs `db_host` and
# the server CA file, neither of which exists until this instance is up and
# `database/setup.sh` has run against its public IP. Applying them separately
# keeps that ordering natural instead of needing -target.
#
#   terraform -chdir=terraform/db init
#   terraform -chdir=terraform/db apply
#   terraform -chdir=terraform/db output -raw public_ip   # -> db_host
#
# The Lambda is NOT in a VPC (a Lambda ENI never gets a public IP, so an
# internet-gateway route can't give it egress to the Teleport proxy). It
# therefore reaches this instance over the internet via its public IP.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws   = { source = "hashicorp/aws", version = ">= 5.0" }
    tls   = { source = "hashicorp/tls", version = ">= 4.0" }
    local = { source = "hashicorp/local", version = ">= 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  type    = string
  default = "vpc-130d6375"
}

variable "subnet_id" {
  description = "Public subnet; the instance needs a public IP so the (non-VPC) Lambda can reach it."
  type        = string
  default     = "subnet-4f520514"
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH in for setup."
  type        = string
  default     = "70.108.34.53/32"
}

variable "instance_type" {
  type    = string
  default = "t4g.micro"
}

variable "ami" {
  description = "Leave empty to look up the latest AL2023 for this region. Set to pin a specific AMI."
  type        = string
  default     = ""
}

# arm64 to match the t4g instance family default.
data "aws_ssm_parameter" "al2023" {
  count = var.ami == "" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

variable "private_key_path" {
  description = "Where the generated SSH private key is written."
  type        = string
  default     = "~/.ssh/tbot-svid-demo.pem"
}

locals {
  ami = var.ami != "" ? var.ami : nonsensitive(data.aws_ssm_parameter.al2023[0].value)

  tags = {
    Name    = "tbot-svid-demo-pg"
    purpose = "tbot-svid-demo-pg"
  }
}

# --- SSH key -----------------------------------------------------------------
# NOTE: the private key is stored in terraform.tfstate in plaintext. State is
# local and gitignored; treat the directory as sensitive. `terraform destroy`
# deletes the local .pem too, and losing state makes the key unrecoverable.

resource "tls_private_key" "pg" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "pg" {
  key_name   = "tbot-svid-demo"
  public_key = tls_private_key.pg.public_key_openssh
  tags       = local.tags
}

resource "local_sensitive_file" "pg_key" {
  content         = tls_private_key.pg.private_key_openssh
  filename        = pathexpand(var.private_key_path)
  file_permission = "0600"
}

# --- Security group ----------------------------------------------------------

resource "aws_security_group" "pg" {
  name        = "tbot-svid-demo-db"
  description = "tbot SVID demo Postgres"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.pg.id
  description       = "SSH for setup"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# 5432 is open because a non-VPC Lambda has no stable source IP. pg_hba.conf
# permits only `hostssl demo lambda_svid_demo ... cert`, so the sole way in is a
# client cert issued by the Teleport SPIFFE CA. The role has no password.
resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id = aws_security_group.pg.id
  description       = "Postgres, cert auth only"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.pg.id
  description       = "Needed for dnf install"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Instance ----------------------------------------------------------------

resource "aws_instance" "pg" {
  ami                         = local.ami
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.pg.id]
  key_name                    = aws_key_pair.pg.key_name
  associate_public_ip_address = true
  tags                        = local.tags

  # Without this, a newly published AL2023 AMI would replace the running
  # instance on the next apply -- so re-running the notebook stays a no-op.
  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    tags        = local.tags
  }

  metadata_options {
    http_tokens = "required" # IMDSv2
  }
}

# --- Outputs -----------------------------------------------------------------

output "public_ip" {
  description = "Use this as db_host in ../terraform.tfvars and as the setup.sh argument."
  value       = aws_instance.pg.public_ip
}

output "instance_id" {
  value = aws_instance.pg.id
}

output "ssh" {
  value = "ssh -i ${var.private_key_path} ec2-user@${aws_instance.pg.public_ip}"
}
