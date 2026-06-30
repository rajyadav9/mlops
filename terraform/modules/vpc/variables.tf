variable "name" {
  description = "Name prefix for all resources"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet tagging)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "region" {
  description = "AWS region"
  type        = string
}

# For regulated/bank environments this must be false.
# No internet egress path should exist for GPU inference nodes.
variable "enable_nat_gateway" {
  description = "Create NAT gateways for private subnet internet egress. Set false for air-gapped bank environments."
  type        = bool
  default     = false
}

# Public subnets are required only if enable_nat_gateway=true or an internet-facing ALB is needed.
# For internal-only bank deployments, set false — all traffic enters via DirectConnect or VPN.
variable "enable_public_subnets" {
  description = "Create public subnets and an Internet Gateway. Set false for fully private (air-gapped) deployments."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
