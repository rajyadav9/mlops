provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  cluster_name = "${var.name}-eks"

  common_tags = {
    Project     = "mlops-vllm"
    Environment = var.environment
    ManagedBy   = "terraform"
    Team        = "mlops"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name                  = var.name
  cluster_name          = local.cluster_name
  vpc_cidr              = var.vpc_cidr
  region                = var.region
  enable_public_subnets = var.enable_public_subnets
  enable_nat_gateway    = var.enable_nat_gateway
  tags                  = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name           = local.cluster_name
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  region                 = var.region
  enable_public_endpoint = var.enable_public_endpoint
  gpu_instance_type      = var.gpu_instance_type
  gpu_capacity_type      = var.gpu_capacity_type
  gpu_desired_size       = var.gpu_desired_size
  gpu_max_size           = var.gpu_max_size

  enable_general_node_group  = var.enable_general_node_group
  general_node_instance_type = var.general_node_instance_type
  general_node_min_size      = var.general_node_min_size
  general_node_desired_size  = var.general_node_desired_size
  general_node_max_size      = var.general_node_max_size

  tags = local.common_tags
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name = "vllm-inference"
  ci_role_arn     = var.ci_role_arn
  tags            = local.common_tags
}
