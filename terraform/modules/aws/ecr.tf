resource "aws_ecr_repository" "proxy" {
  name = "${var.project_name}-proxy"
  # IMMUTABLE prevents an existing tag from being repointed at different
  # bytes, so a deployed tag always refers to the image that was reviewed.
  # Deploys therefore need a unique tag per build (var.image_tag) rather
  # than overwriting :latest.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-proxy"
  }
}

resource "aws_ecr_lifecycle_policy" "proxy" {
  repository = aws_ecr_repository.proxy.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the 10 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
