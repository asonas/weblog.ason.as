# frozen_string_literal: true

require "pathname"

require_relative "lib/weblog_authoring/app"

run WeblogAuthoring::Application.build(root: Pathname(__dir__))
