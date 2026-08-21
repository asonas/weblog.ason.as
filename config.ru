# frozen_string_literal: true

require "pathname"

require_relative "lib/weblog_authoring/development_app"

run WeblogAuthoring::DevelopmentApp.application(root: Pathname(__dir__))
