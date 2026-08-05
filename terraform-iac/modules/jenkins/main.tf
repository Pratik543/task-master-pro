# Create the Jenkins Server EC2 Instance
resource "aws_instance" "jenkins_server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]


  user_data = file("${path.module}/jenkins-master.sh")

  tags = {
    Name = "Jenkins-Master-Server"
    description = "Jenkins Master Server"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
  }
}

# Create the Jenkins Slave Node EC2 Instance
resource "aws_instance" "jenkins_slave" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]


  user_data = file("${path.module}/jenkins-slave.sh")

  tags = {
    Name = "Jenkins-Slave-Node"
    description = "Jenkins Slave Node, Running SonarQube, Nexus"
  }

  root_block_device {
    volume_size = var.slave_volume_size
    volume_type = "gp3"
  }
}

# Elastic IPs for the Jenkins Server and Slave Node
resource "aws_eip" "jenkins_server" {
  instance = aws_instance.jenkins_server.id
  tags = {
    Name = "Jenkins-Server-EIP"
  }
}

resource "aws_eip" "jenkins_slave_node" {
  instance = aws_instance.jenkins_slave.id
  tags = {
    Name = "Jenkins-Slave-Node-EIP"
  }
}
