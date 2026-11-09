#!/usr/bin/env ruby
# frozen_string_literal: true

# 公開処理（受付・公開ワーカー・再試行・失効）の検証。手順と読み方は同じディレクトリの SKILL.md を参照する。
#
# 実コードの DraftPublication / DraftJobs / DraftStore / DraftOutputStore を、作者・公開ワーカー・
# 障害の操作列で深さ優先に全探索する。各操作の後に公開状態の規則を確かめ、各系列の最後に
# 障害を止めて公開処理を落ち着かせ (settle)、最新の公開処理が完了しているか、記事一覧に
# 要確認が出ているかを確かめる。

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "tmpdir"
require "aws-sdk-cloudfront"

REPO_ROOT = File.expand_path("../../..", __dir__)
$LOAD_PATH.unshift(File.join(REPO_ROOT, "lib"))
require "weblog_authoring/draft_store"
require "weblog_authoring/draft_publication"
require "weblog_authoring/draft_publisher"
require "weblog_authoring/draft_jobs"
require "weblog_authoring/draft_administration"
require "weblog_authoring/development_database"
require "weblog_authoring/published_article_reader"
require "weblog_authoring/local_publication_objects"
require "weblog_authoring/public_cache"

module VerifyPublicationJobs
  SITE_URL = "https://example.com"
  RELEASE = "a" * 40
  SHELL = '<html><head><title>shell</title></head><body><div id="authoring-root"></div></body></html>'
  EMPTY_UPDATE = { "protocol" => 1, "generation" => 1, "data" => "AAA=", "digest" => Digest::SHA256.hexdigest("\0\0"), "body_bytes" => 0 }.freeze
  # DraftOutputStore#fail_publication_stage turns the fifth failed attempt into needs_attention.
  OUTAGE_ATTEMPTS = 5

  ACTIONS = {
    "E" => "本文を編集して「公開する」を押す (DraftStore#append → DraftPublication#prepare・#accept)",
    "U" => "編集せずに「公開する」を押す (DraftPublication#prepare・#accept)",
    "D" => "直前の公開要求を同じ request_id で再送する (応答が届かず「公開を再試行」)",
    "N" => "公開ワーカーが最も古い未処理の受付を処理する (DraftJobs#run, retry_now: true)",
    "L" => "公開ワーカーが最も新しい未処理の受付を先に処理する (DraftJobs#run, retry_now: true)",
    "H" => "次のHTML配置を1回失敗させる (S3の一時失敗)",
    "F" => "次の CreateInvalidation を1回失敗させる (AWSの一時失敗)",
    "K" => "S3障害が続き、最新版のページ生成が5回失敗する (DraftJobs#run を5回、間に1時間ずつ進める)",
    "T" => "記事一覧で「再試行」を押す (最新版に DraftJobs#run, retry_now: true)",
    "P" => "時計を1時間進めて定期修復を実行する (DraftJobs#repair)",
  }.freeze

  RULES = {
    "superseded_published" => "失効した版が、公開中の版になる",
    "active_regressed" => "公開中の版が、それより前に受け付けた版に戻る",
    "webmention_twice" => "Webmentionの送信要求が、最初の公開以外でも作られる",
    "duplicate_version" => "同じ公開要求 (request_id) から、版が2つ以上作られる",
    "finished_not_live" => "記事一覧で最新の公開処理がすべて反映済みなのに、公開中の版が最新版でない",
    "silent_stall" => "障害が止んで公開処理が落ち着いた後、最新の公開処理が完了せず、記事一覧に要確認も出ない",
  }.freeze

  class CurrentOutputs
    def current?(_stage) = true
    def build(_stage) = nil
  end

  # S3 boundary: put_object fails while the world holds pending HTML failures.
  class FlakyObjects
    def initialize(objects, state)
      @objects = objects
      @state = state
    end

    attr_writer :state

    def put_object(**options)
      if @state["html_failures"].positive?
        @state["html_failures"] -= 1
        raise IOError, "S3 put_object failed (simulated)"
      end
      @objects.put_object(**options)
    end

    def method_missing(name, ...)
      @objects.public_send(name, ...)
    end

    def respond_to_missing?(name, include_private = false)
      @objects.respond_to?(name, include_private) || super
    end
  end

  class World
    attr_reader :state

    def initialize(root)
      @root = Pathname(root)
      FileUtils.mkdir_p(@root)
      @state = fresh_state
      @store = WeblogAuthoring::DraftStore.sqlite(@root.join("drafts.sqlite3"), pieces_enabled: false)
      @store.setup!
      @database = WeblogAuthoring::DevelopmentDatabase.new(@root.join("legacy.sqlite3"), content_dir: @root.join("content"))
      @database.setup!
      @reader = WeblogAuthoring::PublishedArticleReader.new(store: @store, database: @database)
      @objects_dir = @root.join("objects")
      local = WeblogAuthoring::LocalPublicationObjects.new(@objects_dir)
      local.put_object(bucket: "site", key: "static/authoring/public.html", body: SHELL)
      local.put_object(bucket: "site", key: "index.html", body: SHELL)
      local.put_object(bucket: "site", key: "display-releases/#{RELEASE}/public.html", body: SHELL)
      local.put_object(bucket: "site", key: "display-releases/current.json", body: JSON.generate("id" => RELEASE))
      @objects = FlakyObjects.new(local, @state)
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
      @administration = WeblogAuthoring::DraftAdministration.new(store: @store, publication: @publication, database: @database)
    end

    # S0: the article "Topic" exists and has never been published.
    def setup_unpublished!
      @article = SecureRandom.uuid
      @bodies[@article] = ->(through) { "Topic の本文 (head #{through})" }
      @store.create(@article, { "protocol" => 1, "generation" => 1 })
      append("title" => { "value" => "Topic", "expected_revision" => 0 })
      @state["trace"] = []
      step("初期状態 S0: 記事 Topic は未公開") { check! }
    end

    # S1: "Topic" is published as v1 and every stage has finished.
    def setup_published!
      setup_unpublished!
      apply("E")
      apply("N")
      settle!
      @state["trace"] = []
      step("初期状態 S1: 記事 Topic は v1 で公開済み、公開処理はすべて完了") { check! }
    end

    def apply(letter)
      step("#{letter}: #{ACTIONS.fetch(letter)}") do
        case letter
        when "E"
          append({})
          accept
        when "U" then accept
        when "D" then resend
        when "N" then run(@state["pending"].shift, "公開ワーカー")
        when "L" then run(@state["pending"].pop, "公開ワーカー")
        when "H" then @state["html_failures"] += 1
        when "F" then @state["cache_failures"] += 1
        when "K" then outage
        when "T" then run(latest_id, "記事一覧の再試行")
        when "P"
          @state["now"] += 3600
          repair
        end
        check!
      end
    end

    # Failures stop, every queued dispatch runs, and the hourly repair runs four
    # times, which is past every retry delay (DraftOutputStore caps it at 3600s).
    def settle!
      step("settle: 障害が止み、未処理の受付を古い順に DraftJobs#run し、3601秒ごとに DraftJobs#repair を4回") do
        @state["html_failures"] = 0
        @state["cache_failures"] = 0
        until @state["pending"].empty?
          run(@state["pending"].shift, "公開ワーカー")
          check!
        end
        4.times do
          @state["now"] += 3601
          repair
          check!
        end
        stall!
      end
    end

    def save(directory)
      FileUtils.mkdir_p(directory)
      FileUtils.cp(@root.join("drafts.sqlite3"), File.join(directory, "drafts.sqlite3"))
      FileUtils.rm_rf(File.join(directory, "objects"))
      FileUtils.cp_r(@objects_dir, File.join(directory, "objects"))
      JSON.generate(@state.merge("now" => @state.fetch("now").iso8601(6)))
    end

    def restore(directory, dump)
      FileUtils.cp(File.join(directory, "drafts.sqlite3"), @root.join("drafts.sqlite3"))
      FileUtils.rm_rf(@objects_dir)
      FileUtils.cp_r(File.join(directory, "objects"), @objects_dir)
      state = JSON.parse(dump)
      @state = state.merge("now" => Time.iso8601(state.fetch("now")))
      @objects.state = @state
    end

    private

    def fresh_state
      { "now" => Time.now.utc, "pending" => [], "html_failures" => 0, "cache_failures" => 0, "names" => {},
        "requests" => 0, "last_request" => nil, "responses" => {}, "highest" => 0, "violations" => {},
        "trace" => [], "errors" => 0, "invalidations" => {}, }
    end

    def cloudfront
      client = Aws::CloudFront::Client.new(stub_responses: true)
      client.stub_responses(:create_invalidation, lambda do |context|
        batch = context.params.fetch(:invalidation_batch)
        reference = batch.fetch(:caller_reference)
        paths = batch.fetch(:paths).fetch(:items)
        if @state["cache_failures"].positive?
          @state["cache_failures"] -= 1
          event("CreateInvalidation → 失敗 (ServiceUnavailable)")
          next "ServiceUnavailable"
        end
        invalidation = @state["invalidations"][reference] ||= { "id" => "I#{@state['invalidations'].size + 1}", "polls" => 0 }
        { invalidation: { id: invalidation.fetch("id"), status: "InProgress", create_time: Time.now,
                          invalidation_batch: { caller_reference: reference, paths: { quantity: paths.length, items: paths } }, } }
      end)
      # The first poll is InProgress (PublicCache::Pending → retry_wait), later polls Completed.
      client.stub_responses(:get_invalidation, lambda do |context|
        invalidation = @state["invalidations"].values.find { |entry| entry.fetch("id") == context.params.fetch(:id) }
        invalidation["polls"] += 1
        status = invalidation.fetch("polls") == 1 ? "InProgress" : "Completed"
        { invalidation: { id: invalidation.fetch("id"), status:, create_time: Time.now,
                          invalidation_batch: { caller_reference: "poll", paths: { quantity: 0 } }, } }
      end)
      client
    end

    def append(metadata)
      @store.append(@article, EMPTY_UPDATE.merge("update_id" => SecureRandom.uuid, "metadata" => metadata))
    end

    def accept
      @state["requests"] += 1
      request = @publication.prepare(@article).merge("request_id" => "request-#{@state['requests']}")
      @state["last_request"] = request
      record(request, @publication.accept(@article, request))
    rescue WeblogAuthoring::DraftStore::Error => error
      event("DraftPublication#accept → 受付拒否 (#{error.message})")
    end

    def resend
      request = @state["last_request"]
      return event("再送する公開要求なし") unless request
      record(request, @publication.accept(@article, request))
    rescue WeblogAuthoring::DraftStore::Error => error
      event("DraftPublication#accept (再送) → 受付拒否 (#{error.message})")
    end

    def record(request, result)
      version = result.fetch("id")
      request_id = request.fetch("request_id")
      previous = @state["responses"][request_id]
      violate("duplicate_version", "#{request_id} が #{name(previous)} と #{name(version)} を返した") if previous && previous != version
      @state["responses"][request_id] = version
      if result.fetch("status") == "accepted" && !@state["names"].key?(version)
        @state["names"][version] = "v#{@state['names'].size + 1}"
        @state["pending"] << version
      end
      event("DraftPublication#accept(#{request_id}) → #{name(version)} #{result.fetch('status')}")
    end

    def run(version, who)
      return event("処理する版なし") unless version
      result = @jobs.run(@article, version, retry_now: true)
      event("#{who}: DraftJobs#run(#{name(version)}) → #{describe(version, result)}")
    rescue StandardError => error
      @state["errors"] += 1
      event("#{who}: DraftJobs#run(#{name(version)}) → 例外 #{error.class}: #{error.message[0, 120]}")
    end

    def outage
      version = latest_id
      return event("処理する版なし") unless version
      @state["html_failures"] += OUTAGE_ATTEMPTS
      OUTAGE_ATTEMPTS.times do
        run(version, "公開ワーカー")
        @state["now"] += 3601
      end
      @state["html_failures"] = 0
    end

    def repair
      result = @jobs.repair
      event("DraftJobs#repair → #{result.fetch('status')} (#{result.fetch('processed')} 件)")
    rescue StandardError => error
      @state["errors"] += 1
      event("DraftJobs#repair → 例外 #{error.class}: #{error.message[0, 120]}")
    end

    def describe(_version, job)
      stages = job.fetch("stages").map { |stage| "#{stage.fetch('stage')}=#{stage.fetch('status')}" }.join(" ")
      "job #{job.fetch('status')}、#{stages}、公開中 #{name(active_id)}"
    end

    def head
      sql("SELECT latest_id, active_id FROM %{prefix}article_publication_heads WHERE article_id = $1", @article).first
    end

    def latest_id = head&.fetch("latest_id")
    def active_id = head&.fetch("active_id")

    def sql(query, *params)
      @store.instance_variable_get(:@connect).call { |db| db.query(format(query, prefix: db.prefix), params) }
    end

    # The publication the article list shows (DraftAdministration#list). attention? mirrors
    # needsAttention in frontend/authoring/DraftAdministration.tsx.
    def list_row
      @administration.list.fetch("articles").find { |article| article.fetch("id") == @article }&.fetch("publication")
    end

    def attention?(row)
      %w[needs_attention superseded].include?(row.fetch("status")) ||
        row.fetch("stages").any? { |stage| %w[needs_attention retry_wait].include?(stage.fetch("status")) }
    end

    def check!
      active = active_id
      jobs = sql("SELECT id, status FROM %{prefix}article_publication_jobs WHERE article_id = $1", @article)
      superseded = jobs.find { |job| job.fetch("status") == "superseded" && job.fetch("id") == active }
      violate("superseded_published", "失効済みの #{name(active)} が公開中") if superseded
      if active
        order = @state["names"].fetch(active, "v0").delete_prefix("v").to_i
        violate("active_regressed", "公開中が #{name(active)} に戻った (以前は v#{@state['highest']})") if order < @state["highest"]
        @state["highest"] = order if order > @state["highest"]
      end
      mentions = sql("SELECT version_id FROM %{prefix}article_webmention_requests WHERE article_id = $1", @article)
      violate("webmention_twice", "送信要求 #{mentions.map { |row| name(row.fetch('version_id')) }.join(', ')}") if mentions.length > 1
      versions = sql("SELECT id FROM %{prefix}article_published_versions WHERE article_id = $1", @article).length
      violate("duplicate_version", "版 #{versions} 個、受付 #{@state['names'].size} 件") if versions > @state["names"].size
      row = list_row
      if row && row.fetch("status") == "completed" && !row.fetch("stages").empty? &&
         row.fetch("stages").all? { |stage| stage.fetch("status") == "completed" } && active != latest_id
        violate("finished_not_live", "一覧の #{name(latest_id)} はすべて反映済み、公開中は #{name(active)}")
      end
    end

    def stall!
      row = list_row
      return unless row
      done = row.fetch("status") == "completed" && active_id == row.fetch("id") &&
             row.fetch("stages").all? { |stage| stage.fetch("status") == "completed" }
      return if done || attention?(row)
      stages = row.fetch("stages").map { |stage| "#{stage.fetch('stage')}=#{stage.fetch('status')}" }.join(" ")
      violate("silent_stall", "一覧の #{name(row.fetch('id'))} は job #{row.fetch('status')}、#{stages.empty? ? 'stageなし' : stages}、公開中 #{name(active_id)}")
    end

    def violate(rule, detail)
      return if @state["violations"].key?(rule)
      @state["violations"][rule] = detail
      event("規則違反 #{rule}: #{detail}")
    end

    def name(version)
      return "なし" unless version
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
      Dir.mktmpdir("verify-publication-jobs") do |directory|
        world = World.new(File.join(directory, "world"))
        world.public_send(ROOTS.fetch(root))
        letters.each { |letter| world.apply(letter) }
        world.settle!
        print_trace(world.state.fetch("trace"))
        found = world.state.fetch("violations")
        found.each { |rule, detail| puts "規則違反 #{rule}: #{RULES.fetch(rule)} (#{detail})" }
        puts "規則違反なし" if found.empty?
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
        Dir.mktmpdir("verify-publication-jobs") do |directory|
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
      world.state.fetch("violations").each do |rule, detail|
        @counts[rule] += 1
        best = @found[rule]
        @found[rule] = { "root" => root, "letters" => prefix, "detail" => detail, "trace" => world.state.fetch("trace") } if best.nil? || best.fetch("letters").length > prefix.length
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
      puts format("所要時間 %.1f 秒。DraftJobs の例外 %d 件", seconds, @errors)
      puts
      RULES.each do |rule, description|
        found = @found[rule]
        unless found
          puts "[成功] #{rule}: 「#{description}」ことはない"
          next
        end
        puts "[失敗] #{rule}: #{description} (#{@counts[rule]} 系列)"
        puts "  最短の反例: #{shortest(found)}"
        self.class.print_trace(found.fetch("trace"))
        puts "  結果: #{found.fetch('detail')}"
        puts
      end
      # One line to compare with the baseline recorded in SKILL.md.
      puts "要約: " + RULES.keys.map { |rule| "#{rule}=#{@counts[rule]}#{@found[rule] ? "(#{shortest(@found[rule])})" : ''}" }.join(" ")
      exit(@found.empty? && @errors.zero? ? 0 : 1)
    end

    def shortest(found)
      "#{found.fetch('root')}:#{found.fetch('letters').join}"
    end
  end
end

depths = { "S0" => 3, "S1" => 3 }
replay = nil
OptionParser.new do |options|
  options.banner = "Usage: check.rb [--s0-depth N] [--s1-depth N] [--replay S1:EKT]"
  options.on("--s0-depth N", Integer, "未公開の記事から探索する操作数 (既定 3)") { |value| depths["S0"] = value }
  options.on("--s1-depth N", Integer, "公開済みの記事から探索する操作数 (既定 3)") { |value| depths["S1"] = value }
  options.on("--replay ROOT:LETTERS", "1つの操作列だけを実行し、すべての出来事を表示する") { |value| replay = value.split(":", 2) }
end.parse!
if replay
  root, letters = replay
  abort "unknown root #{root}" unless VerifyPublicationJobs::Explorer::ROOTS.key?(root)
  abort "unknown action in #{letters}" unless letters.to_s.chars.all? { |letter| VerifyPublicationJobs::ACTIONS.key?(letter) }
  VerifyPublicationJobs::Explorer.replay(root, letters.to_s.chars)
end
VerifyPublicationJobs::Explorer.new(depths:).run
