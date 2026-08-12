terraform {
  backend "s3" {
    bucket  = "task-master-pro-terraform-state"
    key     = "terraform-iac/terraform.tfstate"
    region  = "ap-south-1"
    encrypt = true
  }
}
