output "jenkins_server_public_ip" {
  description = "Public IP of the Jenkins Server instance"
  value       = aws_instance.jenkins_server.public_ip
}

output "jenkins_server_elastic_ip" {
  description = "Elastic IP of the Jenkins Server instance"
  value       = aws_eip.jenkins_server.public_ip
}

output "jenkins_slave_node_public_ip" {
  description = "Public IP of the Jenkins Slave Node instance"
  value       = aws_instance.jenkins_slave.public_ip
}

output "jenkins_slave_node_elastic_ip" {
  description = "Elastic IP of the Jenkins Slave Node instance"
  value       = aws_eip.jenkins_slave_node.public_ip
}

output "jenkins_server_ssh_command" {
  description = "Example SSH command for the Jenkins Server"
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.jenkins_server.public_ip}"
}

output "jenkins_slave_node_ssh_command" {
  description = "Example SSH command for the Jenkins Slave Node"
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.jenkins_slave_node.public_ip}"
}
