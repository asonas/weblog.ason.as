mock_provider "aws" {
  override_during = plan
}

mock_provider "aws" {
  alias           = "us_east_1"
  override_during = plan
}

run "image_inbox_lifecycle" {
  command = plan

  plan_options {
    target = [aws_s3_bucket_lifecycle_configuration.site]
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].id == "expire-image-inbox" && aws_s3_bucket_lifecycle_configuration.site.rule[0].expiration[0].days == 14
    error_message = "assets/inbox objects must expire after 14 days"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].filter[0].prefix == "assets/inbox/"
    error_message = "the image inbox rule must only target assets/inbox"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[1].id == "expire-pending-inbox-adoptions" && aws_s3_bucket_lifecycle_configuration.site.rule[1].expiration[0].days == 14
    error_message = "pending public copies must expire after 14 days"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].prefix == "assets/uploads/"
    error_message = "the pending adoption rule must only target public upload copies"
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].tags) == 1 && lookup(aws_s3_bucket_lifecycle_configuration.site.rule[1].filter[0].and[0].tags, "weblog-inbox-adoption", null) == "pending"
    error_message = "only pending public copies may expire"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.site.rule[0].noncurrent_version_expiration[0].noncurrent_days == 1 && aws_s3_bucket_lifecycle_configuration.site.rule[1].noncurrent_version_expiration[0].noncurrent_days == 1
    error_message = "noncurrent inbox versions must expire after one day"
  }
}
