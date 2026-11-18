# frozen_string_literal: true

module WeblogAuthoring
  module SiteContent
    DIRECTORY = File.join(__dir__, "site_content")
    HOME = File.read(File.join(DIRECTORY, "home.html"), encoding: "UTF-8").freeze
    GUIDE = File.read(File.join(DIRECTORY, "llms.txt"), encoding: "UTF-8").freeze
    ROOT = '<div id="authoring-root"></div>'
    SITE_NAME = '<a href="/">weblog.ason.as</a>'

    # Reactのrootの外に置く。中に置くとcreateRootが読み込み表示に置き換え、読み始めた本文とリンクが消える
    # 静的ヘッダーのサイト名をh1にする。JSが動くホームでは静的ヘッダーが非表示になり、Reactのヘッダーのh1だけが残る
    def self.home(shell)
      shell.dup.force_encoding("UTF-8")
           .sub(SITE_NAME) { %(<h1 class="header-nav__title">#{SITE_NAME}</h1>) }
           .sub(ROOT) { %(#{ROOT}\n<section class="home-guide">#{HOME}</section>) }
    end
  end
end
