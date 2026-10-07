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
  service = WeblogAuthoring::WritingSuggestions.new(reader: database)
  examples = [
    ["spelling", "Ｃｌｏｕｄｆｌａｒｅのキャッシュを有効にしたら、ブログの記事が速く表示された。", "Ｃｌｏｕｄｆｌａｒｅ", "repeated"],
    ["alias", "クラウドフレアをブログの配信に使っている。", "クラウドフレア", "related"],
    ["different entity", "今日のおやつはapple pieだった。りんごをたっぷり使った。", nil, nil],
  ]
  examples.each do |name, text, expected, expected_relation|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = service.call(text:, article_id: "synthetic-draft")
    targets = result.fetch("links").map { |item| item.fetch("target") }
    phrases = result.fetch("links").map { |item| item.fetch("text") }
    passed = expected ? phrases == [expected] && targets == ["Cloudflare"] : targets.empty?
    relations = result.fetch("related").map { |item| item.fetch("relation") }
    passed &&= expected_relation ? relations.include?(expected_relation) : relations.empty?
    puts JSON.generate(case: name, passed:, phrases:, targets:, relations:,
      seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2))
    abort "Evaluation failed: #{name}" unless passed
  end
end
