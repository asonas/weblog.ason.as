# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "pathname"
require "date"
require "time"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "weblog_authoring"
