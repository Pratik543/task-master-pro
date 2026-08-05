variable "project_name" {
  type        = string
  description = "Prefix used to name VPC, subnet, and security group resources"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the new VPC"
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR block for the public subnet"
}

variable "availability_zone" {
  type        = string
  description = "Availability zone for the subnet"
}
