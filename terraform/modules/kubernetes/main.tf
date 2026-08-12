# Compute a hostname per node: node 0 is the control plane, the rest are workers
locals {
  node_hostnames = [
    for i in range(var.instance_count) :
    i == 0 ? "kubernetes-master" : format("kubernetes-worker-%02d", i)
  ]
}

# Create the Kubernetes cluster node EC2 Instances
resource "aws_instance" "k8s_node" {
  count                  = var.instance_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_id]

  # Node 0 is the control plane (master), every other node is a worker.
  # The master runs `kubeadm init`, workers poll SSM for the join command.
  iam_instance_profile = aws_iam_instance_profile.k8s_node.name
  user_data = replace(
    replace(
      file("${path.module}/${count.index == 0 ? "kubernetes-master.sh" : "kubernetes-worker.sh"}"),
      "__SSM_PARAMETER_NAME__",
      var.ssm_parameter_name,
    ),
    "__NODE_HOSTNAME__",
    local.node_hostnames[count.index],
  )

  tags = {
    Name = local.node_hostnames[count.index]
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

# ------------------------------------------------------------------
# IAM: allow nodes to read/write the join command in SSM Parameter Store
# ------------------------------------------------------------------
resource "aws_iam_role" "k8s_node" {
  name = "KubernetesNodeSSMRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "Kubernetes-Node-SSM-Role"
  }
}

resource "aws_iam_role_policy" "k8s_node" {
  name = "KubernetesNodeSSMPolicy"
  role = aws_iam_role.k8s_node.id

  # Scope permissions to ONLY the parameter used for the join command.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:PutParameter",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_parameter_name}"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "k8s_node" {
  name = "KubernetesNodeInstanceProfile"
  role = aws_iam_role.k8s_node.name
}

# Current region + account ID are needed to build the SSM parameter ARN
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}
