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

    assert_equal({
      code:  { copy: true, download: true },
      table: { copy: true, download: true, fullscreen: true },
      image: { download: true },
      link_safety: true
    }, c.controls)
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
