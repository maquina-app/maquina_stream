# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "sqlite3", ">= 2.1"
gem "turbo-rails"

group :development, :test do
  gem "rake"
  gem "minitest"

  # Harness only. The engine ships no JavaScript build step; these serve its
  # `app/javascript` to a browser so the Stimulus controllers can be driven.
  # See test/dummy/app/views/harness and docs/interaction.md.
  gem "importmap-rails"
  gem "stimulus-rails"
  gem "propshaft"
  gem "puma"
end

# The dummy app streams from a real model client, because a fixture string
# proves the engine works against a fixture string. `ruby_llm-test` supplies a
# provider that returns stubbed chunks, so the same path is deterministic under
# test; ollama drives it for real. See test/dummy/app/models/message.rb.
group :development, :test do
  gem "ruby_llm"
  gem "ruby_llm-test", require: false

  # The harness this engine is being built for.
  gem "nexo_ai", require: false
end

group :development, :test do
  gem "standard", "~> 1.0"
  gem "herb", require: false
end
