variable "repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "vllm-inference"
}

variable "ci_role_arn" {
  description = "IAM role ARN that the CI/CD pipeline uses to push images"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
