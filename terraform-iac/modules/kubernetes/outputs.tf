output "kubernetes_node_public_ips" {
  description = "Public IPs of the Kubernetes nodes keyed by node name"
  value = {
    for idx, node in aws_instance.k8s_node : node.tags["Name"] => node.public_ip
  }
}

output "kubernetes_node_elastic_ips" {
  description = "Elastic IPs of the Kubernetes nodes keyed by node name"
  value = {
    for idx, eip in aws_eip.k8s_node : eip.tags["Name"] => eip.public_ip
  }
}

output "kubernetes_node_ssh_commands" {
  description = "Example SSH commands for the Kubernetes nodes keyed by node name"
  value = {
    for idx, node in aws_instance.k8s_node : node.tags["Name"] => "ssh -i ${var.key_name}.pem ubuntu@${node.public_ip}"
  }
}
