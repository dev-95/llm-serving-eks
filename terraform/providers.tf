provider "aws" {
  region = var.region

  # Every resource gets these tags, so leftovers are easy to find.
  default_tags {
    tags = {
      Project   = "llm-serving-eks"
      ManagedBy = "terraform"
    }
  }
}
