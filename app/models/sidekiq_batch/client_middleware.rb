# frozen_string_literal: true

class SidekiqBatch
  # Sidekiq client middleware. Registered outermost (via `chain.prepend`)
  # so that any dedupe/suppression middleware added later with `chain.add`
  # has already decided whether the job will be pushed by the time we
  # inspect the yield result. We enroll only when the chain returns a
  # truthy payload (i.e. the push is going ahead).
  class ClientMiddleware
    def call(_worker_class, job, _queue, _redis_pool)
      result  = yield
      context = ::SidekiqBatch::BatchEnrollmentContext.current

      context.enroll(job) if result && context

      result
    end
  end
end
