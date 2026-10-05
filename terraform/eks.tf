module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  # Reach the API from the laptop with kubectl; nodes use the private endpoint.
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # The IAM identity running terraform gets cluster-admin via an access entry.
  enable_cluster_creator_admin_permissions = true

  # Cost trims for a short-lived demo cluster: no KMS key, no CloudWatch control-plane logs.
  create_kms_key              = false
  encryption_config           = null
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  addons = {
    vpc-cni = {
      before_compute = true # CNI must exist before nodes join, or they stay NotReady
    }
    kube-proxy             = {}
    coredns                = {}
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    cpu = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      labels = {
        workload = "llm"
      }
    }
  }
}
