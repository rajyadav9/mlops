variable "name" {
  description = "Resource name prefix"
  type        = string
  default     = "mlops"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_public_subnets" {
  description = "Create public subnets and IGW. False for air-gapped bank deployments."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways. False for air-gapped bank deployments."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "enable_public_endpoint" {
  description = "Enable EKS public API endpoint (disable after initial setup)"
  type        = bool
  default     = false
}

variable "gpu_instance_type" {
  description = "GPU instance type"
  type        = string
  # g6e.12xlarge: 48 vCPU, 192 GB RAM, 4× NVIDIA L40S (192 GB VRAM total)
  default     = "g6e.12xlarge"
}

variable "enable_general_node_group" {
  description = "Deploy general node group for platform services"
  type        = bool
  default     = true
}

variable "general_node_instance_type" {
  description = "Instance type for the general node group"
  type        = string
  default     = "m7i.4xlarge"
}

variable "general_node_min_size" {
  type    = number
  default = 2
}

variable "general_node_desired_size" {
  type    = number
  default = 3
}

variable "general_node_max_size" {
  type    = number
  default = 8
}

variable "gpu_capacity_type" {
  description = "GPU node capacity type: ON_DEMAND or SPOT"
  type        = string
  default     = "ON_DEMAND"
}

variable "gpu_desired_size" {
  description = "Initial GPU node count"
  type        = number
  default     = 1
}

variable "gpu_max_size" {
  description = "Max GPU nodes for autoscaling"
  type        = number
  default     = 5
}

variable "ci_role_arn" {
  description = "IAM role ARN used by GitHub Actions to push to ECR"
  type        = string
}
