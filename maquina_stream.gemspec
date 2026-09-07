# frozen_string_literal: true

require_relative "lib/maquina_stream/version"

Gem::Specification.new do |spec|
  spec.name = "maquina_stream"
  spec.version = MaquinaStream::VERSION
  spec.authors = ["Mario Alberto Chávez"]
  spec.summary = "Streaming markdown rendering for Rails, server-side."
  spec.description = "Rails engine that renders a streaming markdown buffer to HTML on the " \
                     "server and broadcasts it over Turbo Streams. Only rendered HTML reaches " \
                     "the browser."
  spec.license = "MIT"
  spec.homepage = "https://github.com/maquina-app/maquina_stream"
  spec.metadata = {
    "homepage_uri" => "https://maquina.app",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://rubydoc.info/gems/maquina_stream/#{spec.version}",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 3.3"

  # The documents that document the gem to someone who installs it. Named
  # rather than globbed, so a working note left in docs/ never ships.
  docs = %w[
    getting-started configuration streaming repair
    registries javascript security deferred-renderers
  ].map { |name| "docs/#{name}.md" }.select { |path| File.exist?(path) }

  spec.files = Dir["{app,config,lib}/**/*"] + docs +
    ["README.md", "CHANGELOG.md", "LICENSE.txt", ".rdoc_options"].select { |file| File.exist?(file) }
  spec.require_paths = ["lib"]

  # Comments in lib/ and app/ are Markdown, not RDoc markup. `.rdoc_options`
  # carries the same setting for anyone running `rdoc` in a checkout; these
  # flags carry it for `gem install`, which does not read that file reliably.
  spec.extra_rdoc_files = ["README.md", "CHANGELOG.md", "LICENSE.txt"].select { |file| File.exist?(file) }
  spec.rdoc_options = [
    "--markup", "markdown",
    "--main", "README.md",
    "--title", "maquina_stream #{MaquinaStream::VERSION}",
    "--exclude", "(?:\\A|/)test/",
    "--exclude", "(?:\\A|/)sdd/"
  ]

  spec.add_dependency "rails", ">= 8.0"
  spec.add_dependency "maquina_remend", ">= 0.1"
  spec.add_dependency "commonmarker"
  spec.add_dependency "nokogiri"
  spec.add_dependency "rouge"
end
