# frozen_string_literal: true

require_relative "draft_outputs"

module WeblogAuthoring
  class DraftJobs
    REPAIR_BATCH_SIZE = 50

    def initialize(store:, publisher:, outputs:, webmentions: nil, clock: Time.method(:now))
      @store = store
      @publisher = publisher
      @outputs = outputs
      @clock = clock
      @webmentions = webmentions
    end

    def run(id, version_id, retry_now: false)
      active = @store.published_snapshot(id)
      begin
        rebuild_html = active && active.fetch("id") == version_id && !@publisher.current?(active)
      rescue StandardError => error
        html_error = error
        rebuild_html = true
      end
      perform(id, version_id, "html", retry_now:, rebuild: rebuild_html) do
        raise html_error if html_error
        @publisher.run(id, version_id)
        snapshot = @store.published_snapshot(id)
        if snapshot && snapshot.fetch("id") == version_id && !@publisher.current?(snapshot)
          @store.record_publication_html(id, version_id, @publisher.repair(snapshot))
        end
        nil
      end
      job = @store.publication_job(id, version_id)
      if job.fetch("status") == "completed" && @store.published_snapshot(id)&.fetch("id") == version_id
        %w[atom search].each do |stage|
          begin
            is_current = @outputs.current?(stage)
          rescue StandardError => error
            perform(id, version_id, stage, retry_now:, rebuild: true) { raise error }
            next
          end
          perform(id, version_id, stage, retry_now:, rebuild: !is_current) { is_current ? nil : @outputs.build(stage) }
        end
      end
      @store.supersede_publication_stages(id, now: @clock.call)
      dispatch_webmentions(id)
      job.merge("stages" => @store.publication_stages(id, version_id))
    end

    def repair
      dispatch_webmentions
      repair_outputs = %w[atom search].any? do |stage|
        !@outputs.current?(stage)
      rescue StandardError
        true
      end
      results = []
      limited = false
      @store.publication_repair_jobs.each do |head|
        id = head.fetch("article_id")
        versions = [head.fetch("latest_id"), head["active_id"]].compact.uniq
        versions.each do |version|
          stages = @store.publication_stages(id, version)
          unfinished = stages.length < 3 || stages.any? { |stage| !%w[completed superseded].include?(stage.fetch("status")) }
          active = version == head["active_id"]
          begin
            repair_html = active && !@publisher.current?(@store.published_snapshot(id))
          rescue StandardError
            repair_html = true
          end
          next unless unfinished || repair_html || (active && repair_outputs)
          if results.length >= REPAIR_BATCH_SIZE
            limited = true
            break
          end
          results << run(id, version)
          repair_outputs = false if active
        end
        break if limited
      end
      @store.cleanup_publication_stages(now: @clock.call)
      status = if results.any? { |job| job.fetch("stages").any? { |stage| %w[needs_attention retry_wait].include?(stage.fetch("status")) } }
                 "needs_attention"
               elsif limited
                 "partial"
               else
                 "completed"
               end
      { "status" => status, "processed" => results.length, "jobs" => results }
    end

    private

    def dispatch_webmentions(id = nil)
      @webmentions&.dispatch(id)
    rescue Aws::SQS::Errors::ServiceError => error
      warn JSON.generate("event" => "draft_webmention_dispatch_failed", "article_id" => id, "error" => error.class.name)
    end

    def perform(id, version_id, stage, retry_now:, rebuild: false)
      claim = @store.begin_publication_stage(id, version_id, stage, now: @clock.call, retry_now:, rebuild:)
      return unless claim
      output = yield
      @store.complete_publication_stage(claim, now: @clock.call, output:)
    rescue StandardError => error
      raise unless claim
      @store.fail_publication_stage(claim, error.message, now: @clock.call)
    end
  end
end
