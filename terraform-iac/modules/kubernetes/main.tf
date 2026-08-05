# Create the Kubernetes cluster node EC2 Instances
resource "aws_instance" "k8s_node" {
  count                  = var.instance_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]

  tags = {
    Name = "Kubernetes-Node-0${count.index + 1}"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }
}

# Elastic IPs for each Kubernetes node
resource "aws_eip" "k8s_node" {
  count    = var.instance_count
  instance = aws_instance.k8s_node[count.index].id

  tags = {
    Name = "Kubernetes-Node-EIP-0${count.index + 1}"
  }
}
