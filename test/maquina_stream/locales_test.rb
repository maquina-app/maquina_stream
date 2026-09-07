# frozen_string_literal: true

require "test_helper"
require "yaml"

# Spanish is the default locale and English is the secondary translation. Both
# have to be complete: a control whose label exists in one file and not the
# other renders in the wrong language, and I18n's fallbacks make that silent.
# So it fails here instead.
class MaquinaStream::LocalesTest < ActiveSupport::TestCase
  LOCALE_DIR = Pathname(File.expand_path("../../config/locales", __dir__))

  # Every leaf key path in a locale file, "a.b.c" style, without the locale root.
  def self.key_set(locale)
    tree = YAML.load_file(LOCALE_DIR.join("#{locale}.yml")).fetch(locale.to_s)
    flatten(tree).to_set
  end

  def self.flatten(node, prefix = [])
    node.flat_map do |key, value|
      path = prefix + [key.to_s]
      value.is_a?(Hash) ? flatten(value, path) : [path.join(".")]
    end
  end

  ES = key_set(:es)
  EN = key_set(:en)

  test "both locale files ship" do
    assert_predicate LOCALE_DIR.join("es.yml"), :exist?
    assert_predicate LOCALE_DIR.join("en.yml"), :exist?
  end

  test "es and en have identical key sets" do
    missing_in_en = (ES - EN).to_a.sort
    missing_in_es = (EN - ES).to_a.sort

    assert_empty missing_in_en, "missing from en.yml: #{missing_in_en.join(", ")}"
    assert_empty missing_in_es, "missing from es.yml: #{missing_in_es.join(", ")}"
  end

  test "every key lives under maquina_stream" do
    (ES | EN).each do |key|
      assert key.start_with?("maquina_stream."), "#{key} is outside the engine's namespace"
    end
  end

  test "no translation is blank" do
    %i[es en].each do |locale|
      tree = YAML.load_file(LOCALE_DIR.join("#{locale}.yml")).fetch(locale.to_s)

      self.class.flatten(tree).each do |key|
        value = key.split(".").reduce(tree) { |node, segment| node.fetch(segment) }

        assert value.to_s.present?, "#{locale}.#{key} is blank"
      end
    end
  end

  test "interpolations match between the two files" do
    interpolations = ->(locale) do
      tree = YAML.load_file(LOCALE_DIR.join("#{locale}.yml")).fetch(locale.to_s)

      self.class.flatten(tree).to_h do |key|
        value = key.split(".").reduce(tree) { |node, segment| node.fetch(segment) }
        [key, value.to_s.scan(/%\{(\w+)\}/).flatten.sort]
      end
    end

    assert_equal interpolations.call(:es), interpolations.call(:en),
      "a translation interpolates a variable the other one does not"
  end

  test "the engine puts its locale files on the I18n load path" do
    loaded = I18n.load_path.map { |path| File.expand_path(path) }

    assert_includes loaded, LOCALE_DIR.join("es.yml").to_s
    assert_includes loaded, LOCALE_DIR.join("en.yml").to_s
  end

  test "every label the components ask for is translated in both locales" do
    keys = Pathname
      .glob(Pathname(File.expand_path("../..", __dir__)).join("app/views/maquina_stream/**/*.erb"))
      .flat_map { |path| path.read.scan(/t\(\s*"(maquina_stream\.[a-z0-9_.]+)"/).flatten }
      .reject { |key| key.end_with?(".") } # an interpolated tail, resolved at render time
      .uniq

    assert_operator keys.size, :>, 0, "no translated labels found in the component partials"

    keys.each do |key|
      %i[es en].each do |locale|
        assert I18n.exists?(key, locale), "#{key} is missing from #{locale}.yml"
      end
    end
  end
end
