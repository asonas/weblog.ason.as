#!/usr/bin/env ruby
# frozen_string_literal: true

# 公開キャッシュの検証。手順と読み方は同じディレクトリの SKILL.md を参照する。
#
# 実コードの DraftPublication / DraftJobs / DraftStore / DraftSite / PublicCache を、
# 作者・公開ワーカー・CloudFront の操作列で深さ優先に全探索する。各系列の最後に
# 公開処理を落ち着かせ (settle)、記事の route について CDN が保持する応答が
# origin の現在の応答と同じ版を指すかを確かめる。

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "tmpdir"
require "uri"
require "aws-sdk-cloudfront"

REPO_ROOT = File.expand_path("../../..", __dir__)
$LOAD_PATH.unshift(File.join(REPO_ROOT, "lib"))
require "weblog_authoring/draft_store"
require "weblog_authoring/draft_publication"
require "weblog_authoring/draft_publisher"
require "weblog_authoring/draft_jobs"
require "weblog_authoring/draft_site"
require "weblog_authoring/lambda_api"
require "weblog_authoring/development_database"
require "weblog_authoring/published_article_reader"
require "weblog_authoring/local_publication_objects"
require "weblog_authoring/public_cache"

module VerifyPublicCache
  ROUTES = %w[Topic Renamed].freeze
  PATHS = ROUTES.flat_map { |route| ["/#{route}", "/#{route}/"] }.freeze
  SITE_URL = "https://example.com"
  RELEASE = "a" * 40
  SHELL = '<html><head><title>shell</title></head><body><div id="authoring-root"></div></body></html>'
  EMPTY_UPDATE = { "protocol" => 1, "generation" => 1, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0 }.freeze

  ACTIONS = {
    "E" => "本文を編集して公開を受け付ける (DraftStore#append → DraftPublication#accept)",
    "R" => "タイトルを Topic と Renamed の他方へ変えて公開を受け付ける (改名)",
    "N" => "公開ワーカーが最も古い未処理の版を処理する (DraftJobs#run)",
    "L" => "公開ワーカーが最も新しい未処理の版を先に処理する (DraftJobs#run)",
    "F" => "次の CreateInvalidation を1回だけ失敗させる (AWSの一時失敗)",
    "P" => "時計を60秒進めて定期修復を実行する (DraftJobs#repair)",
  }.freeze

  KINDS = {
    "first_publication_hub" => "初回公開した記事のrouteに、公開前の関連ページ (render_linked_page) が残る",
    "rename_new_route" => "改名で記事が移ったrouteに、改名前の関連ページが残る",
    "rename_old_route" => "改名元のrouteに、改名前の記事・関連ページが残る",
    "same_route_update" => "公開済み記事を更新したのに、同じrouteに更新前の版が残る",
    "other" => "上記以外の不一致",
  }.freeze

  # Publication jobs do not depend on search or Atom outputs for the cache stage.
  class CurrentOutputs
    def current?(_stage) = true
    def build(_stage) = nil
  end

  # Records activations without changing DraftStore behavior.
  module ActivationProbe
    attr_accessor :activation_probe

    def finish_publication(id, version_id, html_key)
      before = published_snapshot(id)&.fetch("id")
      super.tap { activation_probe&.call(id, before, "finish_publication") }
    end

    def finish_rename(id, version_id)
      before = published_snapshot(id)&.fetch("id")
      super.tap { activation_probe&.call(id, before, "finish_rename") }
    end
  end

  class World
    attr_reader :state

    def initialize(root)
      @root = Pathname(root)
      FileUtils.mkdir_p(@root)
      @state = { "now" => Time.now.utc, "edge" => {}, "pending" => [], "failures" => 0, "names" => {},
                 "invalidations" => {}, "requests" => 0, "first_route" => nil, "trace" => [], "errors" => 0, }
      @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"), pieces_enabled: false)
      @store.setup!
      @store.singleton_class.prepend(ActivationProbe)
      @store.activation_probe = method(:activation)
      @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
      @database.setup!
      @reader = WeblogAuthoring::PublishedArticleReader.new(store: @store, database: @database)
      @objects = WeblogAuthoring::LocalPublicationObjects.new(@root.join("objects"))
      @objects.put_object(bucket: "site", key: "static/authoring/public.html", body: SHELL)
      @objects.put_object(bucket: "site", key: "index.html", body: SHELL)
      @objects.put_object(bucket: "site", key: "display-releases/#{RELEASE}/public.html", body: SHELL)
      @objects.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => RELEASE))
      @bodies = {}
      # The TypeScript draft worker is replaced at its boundary: it returns the
      # Markdown for the requested head, which is all verified_result checks.
      @publication = WeblogAuthoring::DraftPublication.new(store: @store, invalidate_cache: true) do |job|
        { "article_id" => job.fetch("article_id"), "protocol" => job.fetch("protocol"), "generation" => job.fetch("generation"),
          "through" => job.fetch("through"), "markdown" => @bodies.fetch(job.fetch("article_id")).call(job.fetch("through")), }
      end
      @publisher = WeblogAuthoring::DraftPublisher.s3(publication: @publication, database: @reader, s3_client: @objects,
        site_bucket: "site", site_url: SITE_URL, shell_key: "static/authoring/public.html")
      @jobs = WeblogAuthoring::DraftJobs.new(store: @store, publisher: @publisher, outputs: CurrentOutputs.new,
        public_cache: WeblogAuthoring::PublicCache.new(client: cloudfront, distribution_id: "site"), clock: -> { @state["now"] })
      api = WeblogAuthoring::LambdaApi.new(database: @database, reader_database: @reader, draft_store: @store, draft_publisher: @publisher)
      @site = WeblogAuthoring::DraftSite.new(api:, reader: @reader, s3_client: @objects, bucket: "site", published: true,
        store: @store, site_url: SITE_URL, dynamic_article_routes: ["*"], public_cache_enabled: true)
    end

    # S0: an unpublished article "Topic"; the published article "Index" links
    # [[Topic]] and [[Renamed]], so both routes serve a linked page.
    def setup_unpublished!
      @index = SecureRandom.uuid
      @bodies[@index] = ->(_through) { "[[Topic]] と [[Renamed]] への参照" }
      @store.create(@index, { "protocol" => 1, "generation" => 1 })
      append(@index, "title" => { "value" => "Index", "expected_revision" => 0 })
      index_version = @publication.accept(@index, @publication.prepare(@index).merge("request_id" => "index")).fetch("id")
      @jobs.run(@index, index_version)
      @article = SecureRandom.uuid
      @bodies[@article] = ->(through) { "Topic の本文 (head #{through})" }
      @store.create(@article, { "protocol" => 1, "generation" => 1 })
      append(@article, "title" => { "value" => "Topic", "expected_revision" => 0 })
      @state["trace"] = []
      step("初期状態 S0: 記事 Topic は未公開。公開記事 Index が [[Topic]] [[Renamed]] を含む") { view_all }
    end

    # S1: "Topic" has been public long enough that the CDN holds nothing for it.
    def setup_published!
      setup_unpublished!
      apply("E")
      apply("N")
      @state["edge"] = {}
      @state["names"] = { @store.published_snapshot(@article).fetch("id") => "v1" }
      @state["first_route"] = "Topic"
      @state["trace"] = []
      step("初期状態 S1: 記事 Topic は v1 で公開済み。CDNは期限切れで空") { view_all }
    end

    def apply(letter)
      step("#{letter}: #{ACTIONS.fetch(letter)}") do
        case letter
        when "E"
          append(@article, {})
          accept
        when "R"
          job = @store.checkpoint_job(@article)
          title = job.dig("metadata", "title")
          append(@article, "title" => { "value" => (ROUTES - [title.fetch("value")]).first, "expected_revision" => title.fetch("revision") })
          accept
        when "N" then run(@state["pending"].shift)
        when "L" then run(@state["pending"].pop)
        when "F" then @state["failures"] += 1
        when "P"
          @state["now"] += 60
          @jobs.repair
        end
        view_all
      end
    end

    # Transient failures end, the worker drains its queue, and scheduled repair
    # runs after every retry delay. Simulated time stays well inside s-maxage.
    def settle!
      step("settle: AWSの失敗が止み、未処理の版を順に DraftJobs#run し、3601秒ごとに DraftJobs#repair を4回") do
        @state["failures"] = 0
        until @state["pending"].empty?
          run(@state["pending"].shift)
          view_all
        end
        4.times do
          @state["now"] += 3601
          @jobs.repair
          view_all
        end
      end
    end

    def violations
      PATHS.filter_map do |path|
        entry = @state["edge"][path]
        next unless entry
        current = identity(path, origin(path))
        next if entry.fetch("tag") == current
        { "path" => path, "cached" => entry.fetch("tag"), "current" => current, "kind" => classify(path, entry, current) }
      end
    end

    def save(directory)
      FileUtils.mkdir_p(directory)
      %w[drafts.sqlite3 legacy.sqlite3].each { |name| FileUtils.cp(@root.join(name), File.join(directory, name)) }
      JSON.generate(@state.merge("now" => @state.fetch("now").iso8601(6)))
    end

    def restore(directory, dump)
      %w[drafts.sqlite3 legacy.sqlite3].each { |name| FileUtils.cp(File.join(directory, name), @root.join(name)) }
      state = JSON.parse(dump)
      @state = state.merge("now" => Time.iso8601(state.fetch("now")))
    end

    private

    def classify(path, entry, current)
      route = path.delete_prefix("/").delete_suffix("/")
      if entry.fetch("tag") == "hub" && current.start_with?("article:")
        entry.fetch("before_first_activation") && @state["first_route"] == route ? "first_publication_hub" : "rename_new_route"
      elsif entry.fetch("tag").start_with?("article:") && current.start_with?("article:")
        "same_route_update"
      elsif !current.start_with?("article:")
        "rename_old_route"
      else
        "other"
      end
    end

    def cloudfront
      client = Aws::CloudFront::Client.new(stub_responses: true)
      client.stub_responses(:create_invalidation, lambda do |context|
        batch = context.params.fetch(:invalidation_batch)
        reference = batch.fetch(:caller_reference)
        paths = batch.fetch(:paths).fetch(:items)
        if @state["failures"].positive?
          @state["failures"] -= 1
          event("CreateInvalidation #{paths.join(' ')} → 失敗 (ServiceUnavailable)")
          next "ServiceUnavailable"
        end
        invalidation = @state["invalidations"][reference]
        unless invalidation
          # A repeated CallerReference returns the existing batch without a new purge.
          invalidation = @state["invalidations"][reference] = { "id" => "I#{@state['invalidations'].size + 1}", "polls" => 0 }
          paths.each { |path| @state["edge"].delete(path) }
          event("CreateInvalidation #{paths.join(' ')} → CDNから削除")
          # A reader arrives right after the purge, before the job continues.
          paths.each { |path| view(path) if PATHS.include?(path) }
        end
        { invalidation: { id: invalidation.fetch("id"), status: "InProgress", create_time: Time.now,
                          invalidation_batch: { caller_reference: reference, paths: { quantity: paths.length, items: paths } }, } }
      end)
      client.stub_responses(:get_invalidation, lambda do |context|
        invalidation = @state["invalidations"].values.find { |entry| entry.fetch("id") == context.params.fetch(:id) }
        invalidation["polls"] += 1
        status = invalidation.fetch("polls") == 1 ? "InProgress" : "Completed"
        { invalidation: { id: invalidation.fetch("id"), status:, create_time: Time.now,
                          invalidation_batch: { caller_reference: "poll", paths: { quantity: 0 } }, } }
      end)
      client
    end

    def append(id, metadata)
      @store.append(id, EMPTY_UPDATE.merge("update_id" => SecureRandom.uuid, "metadata" => metadata))
    end

    def accept
      @state["requests"] += 1
      request = @publication.prepare(@article).merge("request_id" => "request-#{@state['requests']}")
      result = @publication.accept(@article, request)
      if result.fetch("status") == "accepted"
        version = result.fetch("id")
        name = @state["names"][version] ||= "v#{@state['names'].size + 1}"
        @state["pending"] << version
        cache = @store.cache_request(@article, version)
        event("DraftPublication#accept → #{name} を受付 (#{cache ? "キャッシュ要求 #{JSON.parse(cache.fetch('paths')).join(' ')}" : 'キャッシュ要求なし'})")
      else
        event("DraftPublication#accept → #{result.fetch('status')}")
      end
    rescue WeblogAuthoring::DraftStore::Error => error
      event("DraftPublication#accept → 受付拒否 (#{error.message})")
    end

    def run(version)
      return event("処理待ちの版なし") unless version
      result = @jobs.run(@article, version)
      cache = result.fetch("stages").find { |stage| stage.fetch("stage") == "cache" }
      event("DraftJobs#run(#{name(version)}) → job #{result.fetch('status')}#{cache ? "、cache stage #{cache.fetch('status')}" : ''}")
    rescue StandardError => error
      @state["errors"] += 1
      event("DraftJobs#run(#{name(version)}) → 例外 #{error.class}: #{error.message[0, 120]}")
    end

    def activation(id, before, method_name)
      return unless id == @article
      after = @store.published_snapshot(id)
      return unless after && after.fetch("id") != before
      @state["first_route"] ||= after.fetch("route")
      event("#{method_name} → 有効版 #{before ? name(before) : 'なし'} から #{name(after.fetch('id'))} (route #{after.fetch('route')})")
    end

    def view_all
      PATHS.each { |path| view(path) }
    end

    def view(path)
      return if @state["edge"].key?(path)
      response = origin(path)
      return unless cacheable?(response)
      tag = identity(path, response)
      @state["edge"][path] = { "tag" => tag, "before_first_activation" => @store.published_snapshot(@article).nil? }
      event("読者 GET #{path} → CDNが #{tag} を保存 (#{response.dig(:headers, 'cache-control')})")
    end

    def origin(path)
      @site.call("rawPath" => path, "requestContext" => { "http" => { "method" => "GET" } })
    end

    # Mirrors infra/production/hosting.tf: min_ttl = 0 and default_ttl = 0, so
    # CloudFront stores only what the origin marks as shared-cacheable.
    def cacheable?(response)
      directives = response.fetch(:headers, {}).fetch("cache-control", "").split(",").map(&:strip)
      return false if directives.any? { |directive| %w[no-store no-cache private].include?(directive) }
      ttl = directives.find { |directive| directive.start_with?("s-maxage=") } || directives.find { |directive| directive.start_with?("max-age=") }
      ttl.to_s.split("=", 2).last.to_i.positive?
    end

    def identity(path, response)
      route = URI::DEFAULT_PARSER.unescape(path.delete_prefix("/").delete_suffix("/"))
      resolution = @store.resolve_published_route(route)
      if resolution["snapshot"]
        "article:#{name(resolution['snapshot'].fetch('id'))}"
      elsif resolution["redirect"]
        "redirect:#{resolution['redirect']}"
      elsif response.fetch(:statusCode) == 200
        "hub"
      else
        "status:#{response.fetch(:statusCode)}"
      end
    end

    def name(version)
      @state["names"].fetch(version, version.to_s[0, 8])
    end

    def step(title)
      @state["trace"] << { "title" => title, "events" => [] }
      yield
    end

    def event(text)
      @state["trace"].last&.fetch("events")&.push(text)
      nil
    end
  end

  class Explorer
    ROOTS = {
      "S0" => :setup_unpublished!,
      "S1" => :setup_published!,
    }.freeze

    def self.replay(root, letters)
      Dir.mktmpdir("verify-public-cache") do |directory|
        world = World.new(File.join(directory, "world"))
        world.public_send(ROOTS.fetch(root))
        letters.each { |letter| world.apply(letter) }
        world.settle!
        print_trace(world.state.fetch("trace"))
        found = world.violations
        found.each { |violation| puts "不一致 #{violation.fetch('kind')}: #{violation.fetch('path')} のCDN = #{violation.fetch('cached')}、origin = #{violation.fetch('current')}" }
        puts "不一致なし" if found.empty?
        exit(found.empty? && world.state.fetch("errors").zero? ? 0 : 1)
      end
    end

    def self.print_trace(trace)
      trace.each_with_index do |entry, index|
        puts "  #{index}. #{entry.fetch('title')}"
        entry.fetch("events").each { |event| puts "       - #{event}" }
      end
    end

    def initialize(depths:)
      @depths = depths
      @found = {}
      @counts = Hash.new(0)
      @sequences = Hash.new(0)
      @errors = 0
    end

    def run
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @depths.each do |root, depth|
        Dir.mktmpdir("verify-public-cache") do |directory|
          world = World.new(File.join(directory, "world"))
          world.public_send(ROOTS.fetch(root))
          dfs(world, root, [], depth, File.join(directory, "slots"))
        end
      end
      report(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    private

    def dfs(world, root, prefix, remaining, slots)
      slot = File.join(slots, prefix.length.to_s)
      dump = world.save(slot)
      world.settle!
      @sequences[root] += 1
      @errors += world.state.fetch("errors")
      violations = world.violations
      violations.map { |violation| violation.fetch("kind") }.uniq.each { |kind| @counts[kind] += 1 }
      violations.each do |violation|
        kind = violation.fetch("kind")
        best = @found[kind]
        @found[kind] = { "root" => root, "letters" => prefix, "violation" => violation, "trace" => world.state.fetch("trace") } if best.nil? || best.fetch("letters").length > prefix.length
      end
      world.restore(slot, dump)
      return if remaining.zero?

      ACTIONS.each_key do |letter|
        world.restore(slot, dump)
        world.apply(letter)
        dfs(world, root, prefix + [letter], remaining - 1, slots)
      end
      world.restore(slot, dump)
    end

    def report(seconds)
      @depths.each do |root, depth|
        puts "#{root}: 深さ#{depth}までの操作列 #{@sequences[root]} 件を探索"
      end
      puts format("所要時間 %.1f 秒。DraftJobs#run の例外 %d 件", seconds, @errors)
      puts
      KINDS.each do |kind, description|
        found = @found[kind]
        unless found
          puts "[成功] #{kind}: #{description}"
          next
        end
        violation = found.fetch("violation")
        puts "[失敗] #{kind}: #{description} (#{@counts[kind]} 系列)"
        puts "  最短の反例: #{shortest(found)}"
        self.class.print_trace(found.fetch("trace"))
        puts "  結果: #{violation.fetch('path')} のCDN = #{violation.fetch('cached')}、origin = #{violation.fetch('current')}"
        puts
      end
      # One line to compare with the baseline recorded in SKILL.md.
      puts "要約: " + KINDS.keys.map { |kind| "#{kind}=#{@counts[kind]}#{@found[kind] ? "(#{shortest(@found[kind])})" : ''}" }.join(" ")
      exit(@found.empty? && @errors.zero? ? 0 : 1)
    end

    def shortest(found)
      "#{found.fetch('root')}:#{found.fetch('letters').join}"
    end
  end
end

depths = { "S0" => 3, "S1" => 4 }
replay = nil
OptionParser.new do |options|
  options.banner = "Usage: check.rb [--s0-depth N] [--s1-depth N] [--replay S1:RFNE]"
  options.on("--s0-depth N", Integer, "未公開の記事から探索する操作数 (既定 3)") { |value| depths["S0"] = value }
  options.on("--s1-depth N", Integer, "公開済みの記事から探索する操作数 (既定 4)") { |value| depths["S1"] = value }
  options.on("--replay ROOT:LETTERS", "1つの操作列だけを実行し、すべての出来事を表示する") { |value| replay = value.split(":", 2) }
end.parse!
if replay
  root, letters = replay
  abort "unknown root #{root}" unless VerifyPublicCache::Explorer::ROOTS.key?(root)
  abort "unknown action in #{letters}" unless letters.to_s.chars.all? { |letter| VerifyPublicCache::ACTIONS.key?(letter) }
  VerifyPublicCache::Explorer.replay(root, letters.to_s.chars)
end
VerifyPublicCache::Explorer.new(depths:).run
