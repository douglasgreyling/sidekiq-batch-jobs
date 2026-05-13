# frozen_string_literal: true

require_relative "lib/sidekiq/batch/jobs/version"

Gem::Specification.new do |spec|
  spec.name    = "sidekiq-batch-jobs"
  spec.version = Sidekiq::Batch::Jobs::VERSION
  spec.authors = ["Douglas Greyling"]
  spec.email   = ["greyling.douglas@gmail.com"]

  spec.summary               = "Batch tracking and completion callbacks for Sidekiq, backed by ActiveRecord."
  spec.description           = <<~DESC
    A hand-rolled alternative to Sidekiq Pro batches. Track a group of Sidekiq
    jobs as a batch in PostgreSQL, get atomic completion detection, and fire
    a callback worker when the batch finishes (success or failure).
  DESC
  spec.homepage              = "https://github.com/douglasgreyling/sidekiq-batch-jobs"
  spec.license               = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec            = File.basename(__FILE__)
  spec.files         = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml])
    end
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", "~> 7.1.0"
  spec.add_dependency "railties", "~> 7.1.0"
  spec.add_dependency "sidekiq", ">= 7.0", "< 9"

  spec.add_development_dependency "combustion", "~> 1.4"
  spec.add_development_dependency "concurrent-ruby", "~> 1.2"
  spec.add_development_dependency "database_cleaner-active_record", "~> 2.2"
  spec.add_development_dependency "factory_bot", "~> 6.4"
  spec.add_development_dependency "pg", "~> 1.5"
  spec.add_development_dependency "rspec-rails", "~> 6.1"
  spec.add_development_dependency "rspec-sidekiq", "~> 5.0"
  spec.add_development_dependency "shoulda-matchers", "~> 6.0"
end
