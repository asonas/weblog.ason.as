# frozen_string_literal: true

require "aws-sdk-lambda"
require_relative "dsql_database"
require_relative "draft_cutover_api"
require_relative "draft_reader"
require_relative "draft_jobs"
require_relative "remote_draft_jobs"
require_relative "lambda_api"
require_relative "draft_site"

module WeblogAuthoring
  class DraftRuntime
    def self.for_environment
      pool = AuroraDsql::Pg.create_pool(host: ENV.fetch("DSQL_HOST"), user: "weblog_authoring", application_name: "draft-runtime", occ_max_retries: 3)
      store = DraftStore.postgres(pool)
      database = DsqlDatabase.new(host: ENV.fetch("DSQL_HOST"), content_dir: Pathname("/tmp/content"), pool:)
      client = Aws::Lambda::Client.new
      publication = DraftPublication.remote(store:, lambda_client: client, function_name: ENV.fetch("DRAFT_WORKER_FUNCTION_NAME"))
      new(store:, database:, publication:, s3_client: Aws::S3::Client.new, bucket: ENV.fetch("SITE_BUCKET"), site_url: ENV.fetch("FRONTEND_URL", "https://weblog.ason.as"), lambda_client: client, worker_function: ENV.fetch("DRAFT_PUBLICATION_FUNCTION_NAME"))
    end

    def initialize(store:, database:, publication:, s3_client:, bucket:, site_url:, lambda_client:, worker_function:, search_runner: SearchIndexer::QmdRunner.new)
      @store = store
      @database = database
      @publication = publication
      @s3 = s3_client
      @bucket = bucket
      @reader = DraftReader.new(store:, database:)
      @publisher = DraftPublisher.s3(publication:, database: @reader, s3_client:, site_bucket: bucket, site_url:, shell_key: "static/authoring/public.html")
      @outputs = DraftOutputs.new(store:, s3_client:, bucket:, site_url:, search_runner:)
      @jobs = DraftJobs.new(store:, publisher: @publisher, outputs: @outputs)
      @remote_jobs = RemoteDraftJobs.new(store:, lambda_client:, function_name: worker_function)
    end

    def api(options)
      legacy = LambdaApi.new(**options)
      published = LambdaApi.new(**options, reader_database: @reader, draft_store: @store, draft_publication: @publication,
        draft_publisher: @publisher, draft_outputs: @outputs, draft_jobs: @remote_jobs)
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
