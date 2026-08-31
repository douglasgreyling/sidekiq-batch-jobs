# frozen_string_literal: true

class SidekiqBatch
  class ClientMiddleware
    def call(_worker_class, _job, _queue, _redis_pool)
      result  = yield
      context = ::SidekiqBatch::BatchEnrollmentContext.current

      # Enroll the hash the chain returned, not the one we were handed. That
      # return value is what Sidekiq pushes, so it is the one whose jid must be
      # recorded and the one our batch-id stamp has to land on.
      context.enroll(result) if result.is_a?(Hash) && context

      result
    end
  end
end
