# frozen_string_literal: true

require "bundler/setup"
require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

require "standard/rake"

# Options — Markdown markup, title, main page, exclusions — live in
# `.rdoc_options` rather than here, so `rdoc` run by hand in a checkout and
# `gem install` both produce the same documentation.
require "rdoc/task"
RDoc::Task.new do |rdoc|
  rdoc.rdoc_dir = "doc"
end

task default: %i[test standard]

namespace :maquina_stream do
  desc "Regenerate the light and dark highlighting stylesheets from config.themes"
  task :themes do
    require "maquina_stream"

    %i[light dark].each do |scheme|
      path = MaquinaStream::Themes.path(scheme)
      File.write(path, MaquinaStream::Themes.stylesheet(scheme))
      puts "wrote #{path}"
    end
  end
end
