variable "region" {
  description = "AWS region (project is pinned to Ohio)."
  type        = string
  default     = "us-east-2"
}

variable "name" {
  description = "Name prefix for the VPC, EKS cluster, and ECR repo."
  type        = string
  default     = "llm-serving-eks"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be in standard support (extended support costs 6x more)."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. CPU inference needs RAM, so 8 GiB m7i-flex.large (Free plan accounts only allow Free Tier-eligible types)."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Narrow to your IP (x.x.x.x/32) in a tfvars file."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
