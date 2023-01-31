terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
    }

    doormat = {
      source  = "doormat.hashicorp.services/hashicorp-security/doormat"
      version = "~> 0.0.2"
    }
  }
  cloud {
    organization = "djs-tfcb"
    workspaces {
      name = "lab-vault-app"
    }
  }
}

provider "doormat" {}

data "doormat_aws_credentials" "creds" {
  provider = doormat
  role_arn = "arn:aws:iam::365006510262:role/tfc-doormat-role"
}

provider "aws" {
  access_key = data.doormat_aws_credentials.creds.access_key
  secret_key = data.doormat_aws_credentials.creds.secret_key
  token      = data.doormat_aws_credentials.creds.token
  region = "us-east-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu-minimal/images/hvm-ssd/ubuntu-jammy-22.04-amd64-minimal*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

data "aws_vpc" "selected" {
  tags = {
    Name = "djs-lab-vpc"
  }
}


data "aws_subnets" "private" {
  tags = {
    Name = "djs-lab-subnet-private*"
  }
    
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_subnets" "public" {
  tags = {
    Name = "djs-lab-subnet-public*"
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"

  count = 3

  name = "vault-${count.index+1}"

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = "djs-lab"
  monitoring             = true
  vpc_security_group_ids = ["sg-028d1fce460391d4c"]
  subnet_id              = "${element(data.aws_subnets.public.ids, count.index)}"
  associate_public_ip_address = true

  user_data = <<EOF
#!/bin/bash
apt update -y && apt install gpg -y

wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
apt update -y
apt install vault-enterprise consul-enterprise -y

echo "Changing Hostname"
hostname "vault-${count.index+1}"
echo "vault-${count.index+1}" > /etc/hostname
EOF

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

resource "aws_lb" "vault" {
  name               = "vault"
  internal           = false
  load_balancer_type = "network"
  subnets            = data.aws_subnets.public.ids
}

resource "aws_lb_target_group" "vault" {
  name     = "vault"
  port     = 8200
  protocol = "TCP"
  vpc_id   = data.aws_vpc.selected.id
  health_check {
    enabled = true
    matcher = "200,473"
    path = "/v1/sys/health"
  }
}

resource "aws_lb_target_group_attachment" "vault" {
  for_each         = toset([ for instance in module.ec2_instance : instance.id ])
  target_group_arn = aws_lb_target_group.vault.arn
  target_id        = each.key
  port             = 8200
}

data "aws_acm_certificate" "vault" {
  domain   = "vault.schnei.io"
  statuses = ["ISSUED"]
}

resource "aws_lb_listener" "vault" {
  load_balancer_arn = aws_lb.vault.arn
  port              = "443"
  protocol          = "HTTPS"
  certificate_arn   = data.aws_acm_certificate.vault.arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vault.arn
  }
}