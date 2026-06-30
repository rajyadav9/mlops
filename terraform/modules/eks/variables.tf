variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for node groups"
  type        = list(string)
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "enable_public_endpoint" {
  description = "Whether to enable the EKS public API endpoint. Disable in production."
  type        = bool
  default     = false
}

variable "gpu_instance_type" {
  description = "GPU instance type for the inference node group"
  type        = string
  # g6e.12xlarge: 48 vCPU, 192 GB RAM, 4× NVIDIA L40S (48 GB VRAM each = 192 GB total)
  # Fits Qwen2.5-72B in FP8, or 2× Qwen2.5-14B with full tensor parallelism headroom.
  # Previous default was g4dn.xlarge (1× T4 16 GB) — upgrade when model size demands it.
  default = "g6e.12xlarge"
}

variable "gpu_capacity_type" {
  description = "ON_DEMAND or SPOT for GPU nodes"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.gpu_capacity_type)
    error_message = "gpu_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "gpu_desired_size" {
  description = "Initial GPU node count"
  type        = number
  default     = 1
}

variable "gpu_max_size" {
  description = "Maximum GPU node count for autoscaling"
  type        = number
  default     = 5
}

# --- General node group ---
variable "enable_general_node_group" {
  description = "Deploy a general-purpose node group for platform services (monitoring, KEDA, AIBrix control plane, etc.)"
  type        = bool
  default     = true
}

variable "general_node_instance_type" {
  description = "Instance type for the general node group"
  type        = string
  default     = "m7i.4xlarge"  # 16 vCPU, 64 GB RAM — matches terraform-new default
}

variable "general_node_min_size" {
  description = "Minimum nodes in the general node group"
  type        = number
  default     = 2
}

variable "general_node_desired_size" {
  description = "Desired nodes in the general node group"
  type        = number
  default     = 3
}

variable "general_node_max_size" {
  description = "Maximum nodes in the general node group"
  type        = number
  default     = 8
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
