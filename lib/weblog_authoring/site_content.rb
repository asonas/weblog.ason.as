# frozen_string_literal: true

module WeblogAuthoring
  module SiteContent
    DIRECTORY = File.join(__dir__, "site_content")
    HOME = File.read(File.join(DIRECTORY, "home.html"), encoding: "UTF-8").freeze
    GUIDE = File.read(File.join(DIRECTORY, "llms.txt"), encoding: "UTF-8").freeze
    ROOT = '<div id="authoring-root"></div>'

    # Reactのrootの外に置く。中に置くとcreateRootが読み込み表示に置き換え、読み始めた本文とリンクが消える
    def self.home(shell)
      shell.dup.force_encoding("UTF-8").sub(ROOT) { %(#{ROOT}\n<section class="home-guide">#{HOME}</section>) }
    end
  end
end
