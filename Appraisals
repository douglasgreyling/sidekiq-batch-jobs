# frozen_string_literal: true

# One lane per Rails version we claim to support in the gemspec
# (`activerecord >= 6.1, < 9`).
#
# Ruby is NOT chosen here — Appraisal only controls gem versions. The pairing
# matters because Rails 8 and Sidekiq 8 both require Ruby >= 3.2, so the
# rails-8.0 lane cannot resolve or run on the Ruby 3.0 image. docker-compose.yml
# and the CI matrix pair each lane with a Ruby that can run it.

# The environment the gem was extracted from, and the one it has to keep
# working in. Rails 6.1 forces Sidekiq 7: actionpack 6.1 needs rack ~> 2.0
# while Sidekiq 8 needs rack >= 3.2.
appraise "rails-6.1" do
  gem "activerecord", "~> 6.1.7"
  gem "railties",     "~> 6.1.7"
  gem "sidekiq",      "~> 7.3.10"
end

# Still runs on Ruby 3.0, so this costs no extra image — and it is the only
# cheap lane that exercises EnumCompat's `ActiveRecord::VERSION::MAJOR >= 7`
# branch, which the 6.1 lane can never reach.
appraise "rails-7.1" do
  gem "activerecord", "~> 7.1.0"
  gem "railties",     "~> 7.1.0"
  gem "sidekiq",      "~> 7.3"
end

# Needs Ruby >= 3.2. Exercises the half of the range the other lanes cannot:
# ActiveRecord 8 removed the hash form of `enum` entirely, and Sidekiq 8 is a
# major bump for the middleware and API surface.
appraise "rails-8.0" do
  gem "activerecord", "~> 8.0.0"
  gem "railties",     "~> 8.0.0"
  gem "sidekiq",      "~> 8.0"
end
