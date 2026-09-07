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
