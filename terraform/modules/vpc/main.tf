data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

# ── VPC ─────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ── INTERNET GATEWAY (disabled in air-gapped bank deployments) ───────────────
resource "aws_internet_gateway" "main" {
  count  = var.enable_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main.id
  tags   = merge(var.tags, { Name = "${var.name}-igw" })
}

# ── PUBLIC SUBNETS (disabled in air-gapped bank deployments) ────────────────
resource "aws_subnet" "public" {
  count = var.enable_public_subnets ? length(local.azs) : 0

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

# ── PRIVATE SUBNETS ──────────────────────────────────────────────────────────
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(local.azs))
  availability_zone = local.azs[count.index]

  tags = merge(var.tags, {
    Name                              = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  })
}

# ── NAT GATEWAYS (disabled in air-gapped bank deployments) ──────────────────
# WARNING: Enabling NAT GW creates an internet egress path for all pods in
# private subnets. In a regulated bank environment this MUST remain false.
# NetworkPolicies (see k8s/network-policies/) provide a second enforcement
# layer even if this is accidentally re-enabled.
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? length(local.azs) : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? length(local.azs) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = merge(var.tags, { Name = "${var.name}-nat-${local.azs[count.index]}" })
  depends_on    = [aws_internet_gateway.main]
}

# ── ROUTE TABLES ─────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  count  = var.enable_public_subnets ? 1 : 0
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.main.id

  # When NAT GW is disabled there is deliberately no default route.
  # All egress goes through VPC endpoints only.
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[count.index].id
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-private-rt-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "public" {
  count          = var.enable_public_subnets ? length(local.azs) : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ── VPC ENDPOINT SECURITY GROUP ──────────────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name}-vpce-"
  vpc_id      = aws_vpc.main.id
  description = "Allow HTTPS from within VPC to all interface endpoints"

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # No egress needed — endpoints are AWS-managed and do not initiate traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["127.0.0.1/32"]
    description = "Deny all egress from endpoint SG (endpoints are server-side only)"
  }

  tags = merge(var.tags, { Name = "${var.name}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # Full set of interface endpoints required for air-gapped EKS.
  # Pods reach AWS APIs exclusively through these — no NAT GW, no internet path.
  interface_endpoints = {
    # Container image pulls
    "ecr.api" = "com.amazonaws.${var.region}.ecr.api"
    "ecr.dkr" = "com.amazonaws.${var.region}.ecr.dkr"

    # Secrets & key management
    "secretsmanager" = "com.amazonaws.${var.region}.secretsmanager"
    "kms"            = "com.amazonaws.${var.region}.kms"

    # Identity (IRSA token exchange)
    "sts" = "com.amazonaws.${var.region}.sts"

    # Observability
    "logs"       = "com.amazonaws.${var.region}.logs"
    "monitoring" = "com.amazonaws.${var.region}.monitoring"

    # Node management (no-SSH access via SSM Session Manager)
    "ssm"         = "com.amazonaws.${var.region}.ssm"
    "ssmmessages" = "com.amazonaws.${var.region}.ssmmessages"
    "ec2messages" = "com.amazonaws.${var.region}.ec2messages"

    # EKS control plane & node registration
    "eks" = "com.amazonaws.${var.region}.eks"
    "ec2" = "com.amazonaws.${var.region}.ec2"

    # Node autoscaling (Karpenter / Cluster Autoscaler)
    "autoscaling" = "com.amazonaws.${var.region}.autoscaling"

    # Load balancer controller
    "elasticloadbalancing" = "com.amazonaws.${var.region}.elasticloadbalancing"

    # Async request queue layer (used at scale — see §5 of design doc)
    "sqs" = "com.amazonaws.${var.region}.sqs"
  }
}

# ── INTERFACE VPC ENDPOINTS ───────────────────────────────────────────────────
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.main.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.key}-endpoint" })
}

# ── S3 GATEWAY ENDPOINT ───────────────────────────────────────────────────────
# Gateway endpoints are free and inject routes into the route tables directly.
# Used for: model weight downloads (S3), ECR layer storage, Loki/Tempo object store.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}
