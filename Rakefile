# frozen_string_literal: true

require "bundler/gem_tasks"
require "pathname"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]

desc "Check the active lockfile against the ruby-advisory-db"
task :audit do
  # bundler-audit's own rake task hardcodes ./Gemfile.lock, which silently
  # audits the wrong lane when BUNDLE_GEMFILE points at gemfiles/. Ask Bundler
  # which lockfile is actually in play instead.
  # bundler-audit resolves --gemfile-lock against the project root, so an
  # absolute path makes it report the file as missing.
  lockfile = Bundler.default_lockfile.relative_path_from(Pathname.pwd)

  sh "bundle-audit check --update --gemfile-lock #{lockfile}"
end
