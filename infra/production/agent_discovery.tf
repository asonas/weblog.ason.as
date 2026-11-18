# Route 53 does not support unknown SvcParamKeys. Advertise URLs in companion TXT records.
resource "aws_route53_record" "agent_discovery" {
  for_each = toset(["_index", "_mcp"])

  zone_id = data.aws_route53_zone.ason_as.zone_id
  name    = "${each.value}._agents.weblog.ason.as"
  type    = "HTTPS"
  ttl     = 300
  records = ["1 weblog.ason.as. alpn=\"h2,http/1.1\" port=443"]
}

resource "aws_route53_record" "agent_discovery_metadata" {
  for_each = { "_index" = "agents", "_mcp" = "mcp" }

  zone_id = data.aws_route53_zone.ason_as.zone_id
  name    = "${each.key}._agents.weblog.ason.as"
  type    = "TXT"
  ttl     = 300
  records = ["\"url=https://weblog.ason.as/api/${each.value}\""]
}

# ason.as is the authoritative zone for weblog.ason.as. Signing only a child
# discovery zone would still require signing this parent to establish trust.
data "aws_iam_policy_document" "ason_as_dnssec" {
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "Route53Signing"
    actions   = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:route53:::hostedzone/${data.aws_route53_zone.ason_as.zone_id}"]
    }
  }

  statement {
    sid       = "Route53Grant"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["dnssec-route53.amazonaws.com"]
    }
    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "ason_as_dnssec" {
  provider                 = aws.us_east_1
  description              = "DNSSEC key-signing key for ason.as"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.ason_as_dnssec.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_key_signing_key" "ason_as" {
  hosted_zone_id             = data.aws_route53_zone.ason_as.zone_id
  key_management_service_arn = aws_kms_key.ason_as_dnssec.arn
  name                       = "ason_as_dnssec"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_route53_hosted_zone_dnssec" "ason_as" {
  hosted_zone_id = data.aws_route53_zone.ason_as.zone_id
  depends_on     = [aws_route53_key_signing_key.ason_as]

  lifecycle {
    prevent_destroy = true
  }
}

output "ason_as_dnssec_ds_record" {
  description = "Register this DS at the ason.as registrar after verifying Route 53 signatures."
  value       = aws_route53_key_signing_key.ason_as.ds_record
}
