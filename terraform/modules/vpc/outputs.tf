output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
  # Empty list when enable_public_subnets = false (air-gapped bank deployment)
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}
