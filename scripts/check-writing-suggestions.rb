# frozen_string_literal: true

require "tmpdir"
require "pathname"
require_relative "../lib/weblog_authoring/development_database"
require_relative "../lib/weblog_authoring/writing_suggestions"

abort "TYPESAFE_API_KEY is not configured" unless ENV["TYPESAFE_API_KEY"] && !ENV["TYPESAFE_API_KEY"].empty?

Dir.mktmpdir("writing-suggestions-evaluation") do |directory|
  database = WeblogAuthoring::DevelopmentDatabase.new(Pathname(directory).join("articles.sqlite3"), content_dir: Pathname(directory).join("content"))
  database.setup!
  database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "Cloudflare", body: "クラウドフレアのキャッシュを利用すると、ブログの記事を速く表示できた。"))
  database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "Apple", body: "AppleはMacやiPhoneを開発している会社。"))
  database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "Scrapboxの使い方", body: "基本的な使い方を試してみよう。行頭にスペースを入れて段落を作ることができます。角括弧で囲むと別ページへのリンクになります。"))
  database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "embedのテストをするよ", body: "例えばblueskyのリンクを貼ってみる。"))
  database.save(WeblogAuthoring::SaveRequest.new(page_type: "named", name: "リンクの振る舞いについてのテスト", body: "リンク、貼り方、2024年。"))
  service = WeblogAuthoring::WritingSuggestions.new(reader: database)
  examples = [
    ["spelling", "Ｃｌｏｕｄｆｌａｒｅのキャッシュを有効にしたら、ブログの記事が速く表示された。", "Ｃｌｏｕｄｆｌａｒｅ", "repeated"],
    ["alias without shared claim", "クラウドフレアをブログの配信に使っている。", "クラウドフレア", nil],
    ["contrasting experience", "Cloudflareのキャッシュを有効にしたが、今回はブログの記事の表示が遅くなった。", "Cloudflare", "related"],
    ["different entity", "今日のおやつはapple pieだった。りんごをたっぷり使った。", nil, nil],
    ["writing experiment is not a link tutorial", "猫についてかいてみるけどどうかな。ここで猫をリンクできるだろうか。\n[[WikiMarkdownReact]]についてかいてみよう。これはリンク候補にでるはず。", nil, nil],
  ]
  examples.each do |name, text, expected, expected_relation|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.call(text:, article_id: "synthetic-draft")
    targets = result.fetch("links").map { |item| item.fetch("target") }
    phrases = result.fetch("links").map { |item| item.fetch("text") }
    passed = expected ? phrases == [expected] && targets == ["Cloudflare"] : targets.empty?
    relations = result.fetch("related").map { |item| item.fetch("relation") }
    passed &&= expected_relation ? relations.include?(expected_relation) : relations.empty?
    passed &&= result.fetch("related").all? { |item| !item.fetch("writing_excerpt").empty? && text.include?(item.fetch("writing_excerpt")) }
    puts JSON.generate(case: name, passed:, phrases:, targets:, relations:,
      seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2))
    abort "Evaluation failed: #{name}" unless passed
  end
end
