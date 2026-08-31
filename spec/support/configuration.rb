# frozen_string_literal: true

# Config is global mutable state, and the dummy app sets a non-default base class
# at boot (see spec/internal/config/initializers/sidekiq_batch_jobs.rb). Snapshot
# the whole object around every example so a spec that tweaks a knob cannot leak
# into the next one, and so restoring never has to know which knobs exist.
RSpec.configure do |config|
  config.around do |example|
    saved = Sidekiq::Batch::Jobs.config.dup
    example.run
  ensure
    Sidekiq::Batch::Jobs.config = saved
  end
end
