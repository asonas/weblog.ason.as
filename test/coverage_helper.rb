# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  coverage_dir "coverage/ruby"
  track_files "{lib,lambda}/**/*.rb"

  add_group "Persistence", %r{/lib/weblog_authoring/(?:development_database|dsql_database|dsql_importer)\.rb\z}
  add_group "Authentication and authorization",
            %r{/lib/weblog_authoring/(?:development_app|github_oauth|lambda_api|lambda_session|mobile_upload|production_secrets)\.rb\z}
  add_group "Writing", %r{/lib/weblog_authoring/(?:development_app|lambda_api|inbox_sync)\.rb\z}
  add_group "Migration repair", %r{/lib/weblog_authoring/(?:scrapbox_line_metadata_importer|scrapbox_list_repair)\.rb\z}
  add_group "Feed", %r{/lib/weblog_authoring/atom_feed\.rb\z}
end
