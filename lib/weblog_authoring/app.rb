# frozen_string_literal: true

require "pathname"
require "time"

require_relative "../weblog_authoring"

module WeblogAuthoring
  class Application
    ROOT = Pathname(__dir__).join("../..").expand_path.freeze

    def self.build(root: ROOT, clock: -> { Time.now.getlocal(TOKYO_OFFSET) })
      root_path = Pathname(root).expand_path
      content_dir = root_path.join("content")
      database_path = root_path.join("data/index/authoring.sqlite3")
      site_dir = root_path.join("site")

      content_dir.mkpath
      repository = ContentRepository.new(content_dir, database_path, clock)
      publisher = StaticPublisher.new(
        site_dir,
        release_manifest_path: content_dir.join(".authoring-release.json")
      )
      service = AuthoringService.new(repository, publisher, clock:)
      repository.refresh

      WebApp.new(service)
    end
  end
end
