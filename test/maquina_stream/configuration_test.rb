# frozen_string_literal: true

require "test_helper"

class MaquinaStream::ConfigurationTest < ActiveSupport::TestCase
  setup { MaquinaStream.reset_configuration! }

  test "documented defaults" do
    c = MaquinaStream.config

    assert_equal 60, c.frame_budget_ms
    assert_equal 4_000, c.keyframe_interval_ms
    assert_equal 2, c.seal_lag
    assert_equal :es, c.locale
    assert_equal :maquina, c.components
    assert_equal({ light: "github.light", dark: "github.dark" }, c.themes)

    assert_nil c.default_origin
    assert_equal %w[http https mailto], c.allowed_protocols
    assert_equal ["*"], c.allowed_link_prefixes
    assert_equal ["*"], c.allowed_image_prefixes
    assert c.allow_data_images

    # The four documented groups, with their documented defaults, plus the two
    # Phase 5 components' own controls.
    assert_equal({ copy: true, download: true }, c.controls[:code])
    assert_equal({ copy: true, download: true, fullscreen: true }, c.controls[:table])
    assert_equal({ download: true }, c.controls[:image])
    assert_equal true, c.controls[:link_safety]
    assert_equal({ download: true, remove: true }, c.controls[:attachment])
    assert_equal({ enabled: true }, c.controls[:suggestion])
  end

  test "a control is switchable one at a time, and the rest stay as they were" do
    MaquinaStream.configure { |c| c.controls = { code: { copy: false } } }
    c = MaquinaStream.config

    assert_not c.control?(:code, :copy)
    assert c.control?(:code, :download)
    assert c.control?(:table, :fullscreen)
    assert c.control?(:link_safety)
  end

  test "disabling everything is one expression" do
    MaquinaStream.configure { |c| c.controls = false }
    c = MaquinaStream.config

    MaquinaStream::Configuration::DEFAULT_CONTROLS.each_key do |group|
      assert_not c.control?(group), "#{group} survived a wholesale disable"
    end

    MaquinaStream.configure { |c| c.controls = true }

    assert MaquinaStream.config.control?(:table, :copy)
  end

  test "control? answers for a group and for one control" do
    c = MaquinaStream.config

    assert c.control?(:code, :copy)
    assert c.control?(:code), "a group with anything enabled is enabled"
    assert_not c.control?(:code, :nonexistent)

    c.controls = { code: { copy: false, download: false } }

    assert_not c.control?(:code), "a group with nothing left enabled is disabled"
  end

  test "link_safety is a flag, not a group, and reads the same way" do
    assert MaquinaStream.config.control?(:link_safety)

    MaquinaStream.configure { |c| c.controls = { link_safety: false } }

    assert_not MaquinaStream.config.control?(:link_safety)
  end

  test "configure yields the config and keeps the assignment" do
    returned = MaquinaStream.configure do |c|
      c.frame_budget_ms = 80
      c.locale = :en
    end

    assert_equal MaquinaStream.config, returned
    assert_equal 80, MaquinaStream.config.frame_budget_ms
    assert_equal :en, MaquinaStream.config.locale
  end

  test "transport defaults to turbo streams and is a seam" do
    assert_equal :turbo_streams, MaquinaStream.config.transport

    MaquinaStream.configure { |c| c.transport = :sse }

    assert_equal :sse, MaquinaStream.config.transport
  end

  test "authorization denies when the host configured no callable" do
    assert_not MaquinaStream.config.authorized?(messages(:streaming), nil)
  end

  test "authorization delegates to the host callable" do
    MaquinaStream.configure { |c| c.authorize = ->(record, _request) { record.stream_status == "open" } }

    assert MaquinaStream.config.authorized?(messages(:streaming), nil)
    assert_not MaquinaStream.config.authorized?(messages(:sealed), nil)
  end

  test "find_stream! refuses when the host configured no finder" do
    error = assert_raises(MaquinaStream::ConfigurationError) { MaquinaStream.config.find_stream!("1") }

    assert_match "find_stream", error.message
  end
end
