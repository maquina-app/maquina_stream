# frozen_string_literal: true

require_relative "lib/maquina_stream/version"

Gem::Specification.new do |spec|
  spec.name = "maquina_stream"
  spec.version = MaquinaStream::VERSION
  spec.authors = ["Mario Chavez"]
  spec.summary = "Streaming markdown rendering for Rails, server-side."
  spec.description = "Rails engine that renders a streaming markdown buffer to HTML on the " \
                     "server and broadcasts it over Turbo Streams. Only rendered HTML reaches " \
                     "the browser."
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["{app,config,lib}/**/*", "docs/**/*", "CLAUDE.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.0"
  # TODO: handoff DoD requires the released maquina_remend gem. Until it ships,
  # the Gemfile overrides this with a path reference to ../maquina_remend.
  spec.add_dependency "maquina_remend"
  spec.add_dependency "commonmarker"
  spec.add_dependency "nokogiri"
  spec.add_dependency "rouge"
end
