resource "aws_s3_bucket" "cost_export" {
  bucket = "weblog-cost-export-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cost_export" {
  bucket                  = aws_s3_bucket.cost_export.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cost_export" {
  bucket = aws_s3_bucket.cost_export.id
  rule {
    id     = "expire-cost-reports"
    status = "Enabled"
    filter {
      prefix = "cur/"
    }
    expiration {
      days = 90
    }
  }
}

data "aws_iam_policy_document" "cost_export" {
  statement {
    sid       = "CostExportDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cost_export.arn}/cur/*"]
    principals {
      type        = "Service"
      identifiers = ["bcm-data-exports.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "cost_export" {
  bucket = aws_s3_bucket.cost_export.id
  policy = data.aws_iam_policy_document.cost_export.json
}

resource "aws_bcmdataexports_export" "daily_cost" {
  provider = aws.us_east_1
  export {
    name        = "weblog-daily-cost"
    description = "Daily resource-level costs for local analysis without repeated Cost Explorer queries."
    data_query {
      query_statement = <<-SQL
        SELECT identity_line_item_id, bill_billing_period_start_date,
               line_item_usage_start_date, line_item_usage_end_date,
               line_item_product_code, line_item_resource_id,
               line_item_usage_type, line_item_operation, line_item_line_item_type,
               line_item_usage_amount, pricing_unit,
               line_item_unblended_cost, line_item_currency_code
        FROM COST_AND_USAGE_REPORT
      SQL
      table_configurations = {
        COST_AND_USAGE_REPORT = {
          BILLING_VIEW_ARN                      = "arn:aws:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"
          TIME_GRANULARITY                      = "DAILY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
        }
      }
    }
    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cost_export.id
        s3_prefix = "cur"
        s3_region = var.aws_region
        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "TEXT_OR_CSV"
          compression = "GZIP"
          output_type = "CUSTOM"
        }
      }
    }
    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }
  depends_on = [aws_s3_bucket_policy.cost_export, aws_s3_bucket_public_access_block.cost_export]
}
