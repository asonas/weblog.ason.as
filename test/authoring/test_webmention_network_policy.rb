# frozen_string_literal: true

require_relative "../test_helper"
require "weblog_authoring/webmention_network_policy"

class WebmentionNetworkPolicyTest < Minitest::Test
  def test_allows_public_addresses
    assert WeblogAuthoring::WebmentionNetworkPolicy.public_address?(IPAddr.new("8.8.8.8"))
    assert WeblogAuthoring::WebmentionNetworkPolicy.public_address?(IPAddr.new("2606:4700:4700::1111"))
  end

  def test_blocks_local_reserved_and_mapped_addresses
    %w[0.0.0.0 10.0.0.1 100.64.0.1 127.0.0.1 169.254.169.254 192.168.1.1 203.0.113.1 ::1 fe80::1 fc00::1 ::ffff:127.0.0.1].each do |value|
      refute WeblogAuthoring::WebmentionNetworkPolicy.public_address?(IPAddr.new(value)), value
    end
  end
end
