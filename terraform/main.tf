# Fetch the latest free Ubuntu 24.04 AMI from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = var.ubuntu_ami_owners

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Create the VPC, subnet, route table, and security group
module "network" {
  source            = "./modules/network"
  project_name      = var.project_name
  vpc_cidr          = var.vpc_cidr
  subnet_cidr       = var.subnet_cidr
  availability_zone = var.availability_zone
}

# Create the Jenkins Server and Slave Node instances
module "jenkins" {
  source        = "./modules/jenkins"
  ami_id        = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = module.network.subnet_id
  sg_id         = module.network.sg_id
}

# Create the Kubernetes cluster nodes
module "kubernetes" {
  count          = var.enable_kubernetes ? 1 : 0
  source         = "./modules/kubernetes"
  ami_id         = data.aws_ami.ubuntu.id
  instance_type  = var.kubernetes_instance_type
  instance_count = var.kubernetes_instance_count
  key_name       = var.key_name
  subnet_id      = module.network.subnet_id
  sg_id          = module.network.sg_id
}


