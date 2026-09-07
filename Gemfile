# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# TODO: replace with the released gem once maquina_remend is published.
# The handoff DoD requires the released gem, not this path reference.
gem "maquina_remend", path: "../maquina_remend"

gem "sqlite3", ">= 2.1"
gem "turbo-rails"

group :development, :test do
  gem "rake"
  gem "minitest"

  # Harness only. The engine ships no JavaScript build step; these serve its
  # `app/javascript` to a browser so the Stimulus controllers can be driven.
  # See test/dummy/app/views/harness and docs/interaction.md.
  gem "importmap-rails"
  gem "propshaft"
  gem "puma"
end
