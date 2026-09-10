# frozen_string_literal: true

require_relative "coverage_helper" if ENV["COVERAGE"] == "1"

require "minitest/autorun"
require "json"
require "pathname"
require "tmpdir"
require "date"
require "time"

SYSTEM_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

def require_system_chrome
  chrome = ENV.fetch("ARTICLE_COMPARISON_CHROME_PATH", SYSTEM_CHROME)
  skip "System Google Chrome is required for local visual comparison" unless File.executable?(chrome)
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "weblog_migration"
