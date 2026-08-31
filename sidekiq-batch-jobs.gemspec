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
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"]          = spec.homepage
  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Development-only paths. Everything else git tracks is packaged, so a new
  # source file ships as soon as it is committed — and packaging_spec.rb fails if
  # one is written but never added.
  gemspec_file = File.basename(__FILE__)
  dev_only     = %w[
    .dockerignore
    .github/
    .gitignore
    .rspec
    .rubocop.yml
    Appraisals
    Dockerfile
    Gemfile
    ROADMAP.md
    bin/
    docker-compose.yml
    docker/
    gemfiles/
    spec/
  ].freeze

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      f == gemspec_file || f.start_with?(*dev_only)
    end
  end

  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 6.1", "< 9"
  spec.add_dependency "railties", ">= 6.1", "< 9"
  spec.add_dependency "sidekiq", ">= 7.0", "< 9"
end
