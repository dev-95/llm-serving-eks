resource "aws_ecr_repository" "llm_server" {
  name                 = "${var.name}/llm-server"
  image_tag_mutability = "IMMUTABLE" # forces versioned tags, no silent overwrites

  # Lets `terraform destroy` remove the repo even when it still holds images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Model images are ~1-2 GB; keep only the last 5 to cap storage cost.
resource "aws_ecr_lifecycle_policy" "llm_server" {
  repository = aws_ecr_repository.llm_server.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}
