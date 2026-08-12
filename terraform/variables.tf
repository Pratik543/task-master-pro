variable "ubuntu_ami_owners" {
  type        = list(string)
  default     = ["099720109477"]
  description = "Account IDs that own the AMI (Canonical for Ubuntu)"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the new VPC"
}

variable "subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR block for the public subnet"
}

variable "availability_zone" {
  type        = string
  default     = "ap-south-1a"
  description = "Availability zone for the subnet"
}

variable "project_name" {
  type        = string
  default     = "task-master"
  description = "Prefix used to name VPC, subnet, and security group resources"
}

variable "key_name" {
  type        = string
  default     = ""
  description = "The key name to use for the EC2 instances"
}

variable "instance_type" {
  type        = string
  default     = "" # 't3.micro'=1GB Mem 't3.small'=2GB Mem 'c7i-flex.large'=4GB Mem 'm7i-flex.large'=8GB Mem
  description = "Instance type for the Jenkins Server and Slave Node"
}

variable "kubernetes_instance_type" {
  type        = string
  default     = ""
  description = "Instance type for the Kubernetes cluster nodes"
}

variable "kubernetes_instance_count" {
  type        = number
  default     = 3
  description = "Number of Kubernetes cluster nodes to create"
}

variable "enable_kubernetes" {
  description = "Set true to provision the Kubernetes EC2 instances"
  type        = bool
  default     = false
}

