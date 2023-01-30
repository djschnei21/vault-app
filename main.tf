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
  owners      = ["679593333241"]

  filter {
    name   = "name"
    values = ["ubuntu-minimal/images/hvm-ssd/ubuntu-focal-20.04-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
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

  name = "vault-${count.index}"

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = "djs-lab"
  monitoring             = true
  vpc_security_group_ids = ["sg-028d1fce460391d4c"]
  subnet_id              = "${element(data.aws_subnets.private.ids, count.index)}"

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}