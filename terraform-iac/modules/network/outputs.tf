output "vpc_id" {
  description = "ID of the created VPC"
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID of the created public subnet"
  value       = aws_subnet.public.id
}

output "sg_id" {
  description = "ID of the default security group"
  value       = aws_default_security_group.default.id
}
