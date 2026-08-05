variable "ami_id" {
  type        = string
  description = "AMI ID used for all Kubernetes nodes"
}

variable "instance_type" {
  type        = string
  description = "Instance type for the Kubernetes nodes"
}

variable "instance_count" {
  type        = number
  default     = 3
  description = "Number of Kubernetes nodes to create"
}

variable "key_name" {
  type        = string
  description = "Key pair name used to SSH into the instances"
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID where the instances are launched"
}

variable "sg_id" {
  type        = string
  description = "Security group ID attached to the instances"
}

variable "root_volume_size" {
  type        = number
  default     = 20
  description = "Root volume size (GB) for each Kubernetes node"
}
