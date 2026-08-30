# frozen_string_literal: true

require_relative "coverage_helper" if ENV["COVERAGE"] == "1"

require "minitest/autorun"
require "json"
require "pathname"
require "tmpdir"
require "date"
require "time"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "weblog_migration"
