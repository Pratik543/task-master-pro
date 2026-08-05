variable "ami_id" {
  type        = string
  description = "AMI ID used for both Jenkins instances"
}

variable "instance_type" {
  type        = string
  description = "Instance type for the Jenkins Server and Slave Node"
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
  description = "Root volume size (GB) for the Jenkins Server"
}

variable "slave_volume_size" {
  type        = number
  default     = 25
  description = "Root volume size (GB) for the Jenkins Slave Node"
}
