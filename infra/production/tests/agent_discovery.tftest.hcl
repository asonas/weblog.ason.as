mock_provider "aws" {
  override_data {
    target = data.aws_iam_policy_document.ason_as_dnssec
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "aws" {
  alias = "us_east_1"
}

run "discovery_and_signed_zone" {
  command = plan

  plan_options {
    target = [aws_route53_record.agent_discovery, aws_route53_hosted_zone_dnssec.ason_as]
  }

  assert {
    condition     = aws_route53_record.agent_discovery["_index"].name == "_index._agents.weblog.ason.as" && aws_route53_record.agent_discovery["_mcp"].name == "_mcp._agents.weblog.ason.as"
    error_message = "Publish both the index and MCP discovery entrypoints."
  }

  assert {
    condition     = aws_route53_record.agent_discovery["_index"].type == "HTTPS" && aws_route53_record.agent_discovery["_index"].records == toset(["1 weblog.ason.as. mandatory=alpn,port alpn=\"h2,http/1.1\" port=443 key65001=\"cap=https://weblog.ason.as/api/agents\""])
    error_message = "Discovery must use ServiceMode HTTPS with real ALPNs, port and a numeric experimental descriptor key."
  }

  assert {
    condition     = aws_kms_key.ason_as_dnssec.customer_master_key_spec == "ECC_NIST_P256" && aws_kms_key.ason_as_dnssec.key_usage == "SIGN_VERIFY"
    error_message = "Route 53 requires an asymmetric P-256 signing key."
  }
}
