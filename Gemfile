# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies and the supported version range live in the gemspec.
gemspec

# Development dependencies live here rather than in the gemspec. `~>` caps in a
# gemspec would pin the whole matrix to one era of test tooling, and no single
# constraint can span it: shoulda-matchers 6.x needs Ruby >= 3.0.5, 7.x needs
# >= 3.2 and 8.x needs >= 3.3. Floors let bundler resolve the right version for
# whichever Ruby a lane runs on.
gem "combustion", ">= 1.4"
gem "concurrent-ruby", ">= 1.2"
gem "database_cleaner-active_record", ">= 2.2"
gem "factory_bot", ">= 6.4"
gem "pg", ">= 1.5"
gem "rspec-rails", ">= 6.1"
gem "rspec-sidekiq", ">= 5.0"
gem "shoulda-matchers", ">= 6.0"

gem "appraisal", "~> 2.5"
gem "bundler-audit", "~> 0.9"
gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"
gem "rubocop", "~> 1.21"

# Rails and Sidekiq versions are chosen per lane — see Appraisals. Without a
# constraint here, a bare `bundle install` resolves to the newest that the
# container's Ruby supports.
