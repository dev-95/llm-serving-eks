data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Public subnets only across 2 AZs: no NAT gateway (~$32/month each) for a demo.
# Nodes get public IPs and reach ECR/EKS through the internet gateway.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets          = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  map_public_ip_on_launch = true

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Lets the AWS load balancer integration place internet-facing LBs here.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
}
