# frozen_string_literal: true

require "aws-sdk-lambda"
require "aws-sdk-sqs"
require_relative "dsql_database"
require_relative "draft_cutover_api"
require_relative "draft_reader"
require_relative "lambda_api"
require_relative "draft_site"

module WeblogAuthoring
  class DraftRuntime
    class LazyService
      def initialize(&factory) = @factory = factory

      def method_missing(name, ...) = target.public_send(name, ...)
      def respond_to_missing?(name, include_private = false) = target.respond_to?(name, include_private)

      private

      def target = (@target ||= @factory.call)
    end

    def self.for_environment
      pool = AuroraDsql::Pg.create_pool(host: ENV.fetch("DSQL_HOST"), user: "weblog_authoring", application_name: "draft-runtime", occ_max_retries: 3)
      store = DraftStore.postgres(pool)
      database = DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content"), pool:)
      lambda_client = LazyService.new { Aws::Lambda::Client.new }
      publication = LazyService.new do
        DraftPublication.remote(store:, lambda_client:, function_name: ENV.fetch("DRAFT_WORKER_FUNCTION_NAME"))
      end
      new(store:, database:, publication:, s3_client: LazyService.new { Aws::S3::Client.new },
        bucket: ENV.fetch("SITE_BUCKET"), site_url: ENV.fetch("FRONTEND_URL", "https://weblog.ason.as"),
        lambda_client:, worker_function: ENV.fetch("DRAFT_PUBLICATION_FUNCTION_NAME"), defer_services: true,
        sqs_client: LazyService.new { Aws::SQS::Client.new }, webmention_queue_url: ENV["WEBMENTION_QUEUE_URL"],
        sender_enabled: ENV.fetch("WEBMENTION_SENDER_ENABLED", "false") == "true")
    end

    def initialize(store:, database:, publication:, s3_client:, bucket:, site_url:, lambda_client:, worker_function:,
      search_runner: nil, defer_services: false, sqs_client: nil, webmention_queue_url: nil, sender_enabled: false)
      @store = store
      @database = database
      @publication = publication
      @s3 = s3_client
      @bucket = bucket
      @reader = DraftReader.new(store:, database:)
      @webmentions = DraftWebmentions.new(store:, sqs_client:, queue_url: webmention_queue_url, site_url:, enabled: sender_enabled)
      services = lambda do
        require_relative "draft_jobs"
        require_relative "remote_draft_jobs"
        runner = search_runner || SearchIndexer::QmdRunner.new
        publisher = DraftPublisher.s3(publication:, database: @reader, s3_client:, site_bucket: bucket, site_url:, shell_key: "static/authoring/public.html")
        outputs = DraftOutputs.new(store:, s3_client:, bucket:, site_url:, search_runner: runner)
        { publisher:, outputs:, jobs: DraftJobs.new(store:, publisher:, outputs:, webmentions: @webmentions),
          remote_jobs: RemoteDraftJobs.new(store:, lambda_client:, function_name: worker_function), }
      end
      resolved = nil
      service = ->(name) { LazyService.new { resolved ||= services.call; resolved.fetch(name) } }
      @publisher = defer_services ? service.call(:publisher) : (resolved ||= services.call).fetch(:publisher)
      @outputs = defer_services ? service.call(:outputs) : resolved.fetch(:outputs)
      @jobs = defer_services ? service.call(:jobs) : resolved.fetch(:jobs)
      @remote_jobs = defer_services ? service.call(:remote_jobs) : resolved.fetch(:remote_jobs)
    end

    def api(options)
      legacy = LambdaApi.new(**options)
      published = LambdaApi.new(**options, reader_database: @reader, draft_store: @store, draft_publication: @publication,
        draft_publisher: @publisher, draft_outputs: @outputs, draft_jobs: @remote_jobs, draft_webmentions: @webmentions)
      legacy = DraftSite.new(api: legacy, reader: @database, s3_client: @s3, bucket: @bucket, published: false)
      published = DraftSite.new(api: published, reader: @reader, s3_client: @s3, bucket: @bucket, published: true)
      DraftCutoverApi.new(store: @store, legacy:, published:)
    end

    def work(event)
      @store.with_cutover_operation("draft_publication") do
        if event["operation"] == "draft_repair"
          @jobs.repair
        elsif event["operation"] == "draft_publication"
          token = event.fetch("dispatch_id")
          dispatch = @store.start_publication_dispatch(token)
          return { "status" => "completed" } unless dispatch
          begin
            result = @jobs.run(dispatch.fetch("article_id"), dispatch.fetch("version_id"), retry_now: true)
            @store.finish_publication_dispatch(token)
            result
          rescue StandardError => error
            @store.finish_publication_dispatch(token, error: error.message)
            raise
          end
        else
          raise ArgumentError, "Unsupported draft publication operation"
        end
      end
    end

    def legacy_work
      @store.with_cutover_operation("legacy_publication") { yield }
    end
  end
end
