# frozen_string_literal: true

require "test_helper"

class ThemesTest < ActiveSupport::TestCase
  teardown { MaquinaStream.reset_configuration! }

  test "the committed stylesheets match what the generator produces" do
    %i[light dark].each do |scheme|
      path = MaquinaStream::Themes.path(scheme)

      assert File.exist?(path), "missing #{scheme} stylesheet - run rake maquina_stream:themes"
      assert_equal File.read(path), MaquinaStream::Themes.stylesheet(scheme),
        "the #{scheme} stylesheet has drifted from config.themes - run rake maquina_stream:themes"
    end
  end

  test "dark rules cover both an explicit choice and the system preference" do
    css = MaquinaStream::Themes.stylesheet(:dark)

    assert_includes css, '[data-theme="dark"] [data-ms-code]'
    assert_includes css, "@media (prefers-color-scheme: dark)"
  end

  test "light rules lose to an explicit dark choice" do
    assert_includes MaquinaStream::Themes.stylesheet(:light), ':root:not([data-theme="dark"]) [data-ms-code]'
  end

  test "an unknown theme name raises instead of silently rendering nothing" do
    MaquinaStream.configure { |c| c.themes = {light: "github.light", dark: "no_such_theme"} }

    assert_raises(MaquinaStream::Themes::UnknownTheme) { MaquinaStream::Themes.stylesheet(:dark) }
  end
end
