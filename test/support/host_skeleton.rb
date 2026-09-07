# frozen_string_literal: true

require "fileutils"

# The parts of a stock Rails application the generators reach into, written
# into a throwaway directory.
#
# The generator tests assert against files this produced, not against template
# strings: a template that reads correctly and injects into the wrong place is
# exactly the failure the generators exist to prevent.
module HostSkeleton
  FILES = {
    "Gemfile" => <<~RUBY,
      source "https://rubygems.org"

      gem "rails"
      gem "turbo-rails"
      gem "importmap-rails"
      gem "maquina_stream"
    RUBY

    "config/routes.rb" => <<~RUBY,
      Rails.application.routes.draw do
        root "home#index"
      end
    RUBY

    "config/importmap.rb" => <<~RUBY,
      pin "application"
      pin "@hotwired/stimulus", to: "stimulus.min.js"
    RUBY

    "config/database.yml" => <<~YAML,
      test:
        adapter: sqlite3
        database: ":memory:"
    YAML

    "app/javascript/application.js" => <<~JS,
      import "@hotwired/turbo-rails"
      import "controllers"
    JS

    "app/javascript/controllers/index.js" => <<~JS,
      import { application } from "controllers/application"
    JS

    "app/views/layouts/application.html.erb" => <<~ERB,
      <!DOCTYPE html>
      <html>
        <head>
          <title>Host</title>
          <%= javascript_importmap_tags %>
        </head>
        <body><%= yield %></body>
      </html>
    ERB

    "app/models/application_record.rb" => <<~RUBY
      class ApplicationRecord < ActiveRecord::Base
        primary_abstract_class
      end
    RUBY
  }.freeze

  # Writes the skeleton into `root`, omitting the paths in `without:` so a test
  # can ask what happens to a host that has no importmap, no Stimulus
  # entrypoint or no layout.
  def build_host(root, without: [], overwrite: {})
    FILES.merge(overwrite).each do |path, contents|
      next if without.include?(path)

      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, contents)
    end

    FileUtils.mkdir_p(File.join(root, "db/migrate"))
    root
  end

  def host_file(root, path)
    File.read(File.join(root, path))
  end
end
