# frozen_string_literal: true

module WeblogAuthoring
  class RemoteDraftJobs
    def initialize(store:, lambda_client:, function_name:)
      @store = store
      @lambda = lambda_client
      @function_name = function_name
    end

    def run(id, version_id, retry_now: false) # rubocop:disable Lint/UnusedMethodArgument
      dispatch = @store.queue_publication_dispatch(id, version_id)
      @lambda.invoke(function_name: @function_name, invocation_type: "Event", payload: JSON.generate("operation" => "draft_publication", "dispatch_id" => dispatch.fetch("id")))
      @store.publication_job(id, version_id).merge("dispatch" => dispatch)
    rescue StandardError => error
      @store.finish_publication_dispatch(dispatch.fetch("id"), error: error.message) if dispatch
      raise
    end

    def repair
      @lambda.invoke(function_name: @function_name, invocation_type: "Event", payload: JSON.generate("operation" => "draft_repair"))
      { "status" => "queued" }
    end
  end
end
