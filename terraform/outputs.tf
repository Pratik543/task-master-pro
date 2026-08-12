# ----------- Networking Outputs -----------
output "vpc_id" {
  description = "ID of the created VPC"
  value       = module.network.vpc_id
}

output "subnet_id" {
  description = "ID of the created public subnet"
  value       = module.network.subnet_id
}

output "security_group_id" {
  description = "ID of the default security group"
  value       = module.network.sg_id
}

# ----------- AMI Output -----------
output "ubuntu_instance_ami" {
  description = "AMI ID selected by the filter"
  value       = data.aws_ami.ubuntu.id
}

# ----------- Jenkins Outputs -----------
output "jenkins_server_public_ip" {
  description = "Public IP of the Jenkins Server instance"
  value       = module.jenkins.jenkins_server_public_ip
}

output "jenkins_server_elastic_ip" {
  description = "Elastic IP of the Jenkins Server instance"
  value       = module.jenkins.jenkins_server_elastic_ip
}

output "jenkins_server_ssh_command" {
  description = "Example SSH command for the Jenkins Server"
  value       = module.jenkins.jenkins_server_ssh_command
}

output "jenkins_slave_node_public_ip" {
  description = "Public IP of the Jenkins Slave Node instance"
  value       = module.jenkins.jenkins_slave_node_public_ip
}

output "jenkins_slave_node_elastic_ip" {
  description = "Elastic IP of the Jenkins Slave Node instance"
  value       = module.jenkins.jenkins_slave_node_elastic_ip
}

output "jenkins_slave_node_ssh_command" {
  description = "Example SSH command for the Jenkins Slave Node"
  value       = module.jenkins.jenkins_slave_node_ssh_command
}

# ----------- Kubernetes Outputs -----------
output "kubernetes_node_public_ips" {
  description = "Public IPs of the Kubernetes nodes"
  value       = var.enable_kubernetes ? module.kubernetes[0].kubernetes_node_public_ips : null
}

output "kubernetes_node_elastic_ips" {
  description = "Elastic IPs of the Kubernetes nodes"
  value       = var.enable_kubernetes ? module.kubernetes[0].kubernetes_node_elastic_ips : null
}

output "kubernetes_node_ssh_commands" {
  description = "Example SSH commands for the Kubernetes nodes"
  value       = var.enable_kubernetes ? module.kubernetes[0].kubernetes_node_ssh_commands : null
}
