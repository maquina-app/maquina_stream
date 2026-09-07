# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rails/test_help"

ActiveRecord::Schema.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)

module ActiveSupport
  class TestCase
    self.fixture_paths = [File.expand_path("fixtures", __dir__)]
    fixtures :all

    # Configuration is global; every test starts from the documented defaults
    # and the dummy host's seams.
    setup do
      MaquinaStream.reset_configuration!
      MaquinaStream.reset_registries!
      load File.expand_path("dummy/config/initializers/maquina_stream.rb", __dir__)
    end
  end
end
