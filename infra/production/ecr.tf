resource "aws_ecr_repository" "authoring" {
  name                 = "weblog-authoring-production"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "authoring" {
  repository = aws_ecr_repository.authoring.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the latest ten images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "search_indexer" {
  name                 = "weblog-search-indexer-production"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "search_indexer" {
  repository = aws_ecr_repository.search_indexer.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the latest ten images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "inbox_sync" {
  name                 = "weblog-inbox-sync-production"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "inbox_sync" {
  repository = aws_ecr_repository.inbox_sync.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the latest ten images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_repository" "bluesky_oauth" {
  name                 = "weblog-bluesky-oauth-production"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "bluesky_oauth" {
  repository = aws_ecr_repository.bluesky_oauth.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the latest ten images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
