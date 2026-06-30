output "repository_url" {
  value = aws_ecr_repository.vllm.repository_url
}

output "repository_arn" {
  value = aws_ecr_repository.vllm.arn
}

output "registry_id" {
  value = aws_ecr_repository.vllm.registry_id
}
