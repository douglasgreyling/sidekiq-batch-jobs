# frozen_string_literal: true

# One lane per Rails version we claim to support in the gemspec
# (`activerecord >= 7.2, < 9`).
#
# Ruby is NOT chosen here: Appraisal only controls gem versions. The pairing
# still matters, because Rails 8 and Sidekiq 8 both require Ruby >= 3.2 while
# Rails 7.2 runs on 3.1. docker-compose.yml and the CI matrix pair each lane
# with a Ruby that can run it.

# The floor, and the only lane that proves `required_ruby_version >= 3.1`:
# 7.2 is the newest series that still runs on Ruby 3.1. Sidekiq stays on 7
# for the same reason, which makes this the only lane covering Sidekiq 7 at
# all, so it guards the whole lower half of `sidekiq >= 7.0, < 9`.
appraise "rails-7.2" do
  gem "activerecord", "~> 7.2.0"
  gem "railties",     "~> 7.2.0"
  gem "sidekiq",      "~> 7.3"
end

# Where ActiveRecord dropped the hash form of `enum`, so this lane is what
# holds the models to the positional call. Sidekiq is pinned to the 8.0 series
# rather than `~> 8.0`, which would float to 8.1 and leave the middle of the
# supported Sidekiq range uncovered.
appraise "rails-8.0" do
  gem "activerecord", "~> 8.0.0"
  gem "railties",     "~> 8.0.0"
  gem "sidekiq",      "~> 8.0.0"
end

# The newest supported pairing, and what the `< 9` ceiling is measured against.
appraise "rails-8.1" do
  gem "activerecord", "~> 8.1.0"
  gem "railties",     "~> 8.1.0"
  gem "sidekiq",      "~> 8.1.0"
end
