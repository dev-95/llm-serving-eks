terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.67"
    }
  }

  # Local state on purpose: no remote backend, no idle storage cost.
}
