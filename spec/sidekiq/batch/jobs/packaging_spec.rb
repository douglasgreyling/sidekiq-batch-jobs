# frozen_string_literal: true

require "spec_helper"

# The gemspec builds its file list from `git ls-files`, so a source file that
# exists on disk but was never `git add`ed is silently dropped from the built
# gem. The suite would still pass — it loads from disk — and the breakage would
# only surface for whoever installed the release.
RSpec.describe "the gemspec's file list" do
  subject(:gemspec) { Gem::Specification.load("sidekiq-batch-jobs.gemspec") }

  it "ships every source file under app/ and lib/" do
    on_disk = Dir["app/**/*.rb", "lib/**/*.rb"].sort
    missing = on_disk - gemspec.files

    expect(missing).to be_empty,
                       "these source files would not ship — are they committed?\n  #{missing.join("\n  ")}"
  end

  it "leaves development-only files out of the package" do
    excluded = gemspec.files.grep(%r{\A(spec/|bin/|docker|gemfiles/|\.github/|Appraisals|Dockerfile|ROADMAP)})

    expect(excluded).to be_empty
  end
end
