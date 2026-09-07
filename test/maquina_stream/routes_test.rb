# frozen_string_literal: true

require "test_helper"

class MaquinaStream::RoutesTest < ActionDispatch::IntegrationTest
  test "manifest is routed and served" do
    get "/maquina_stream/#{messages(:streaming).id}/manifest"

    assert_response :success
  end

  test "blocks is routed and served" do
    get "/maquina_stream/#{messages(:streaming).id}/blocks", params: {ids: ["ms-1-b0"]}

    assert_response :success
  end

  test "an unknown stream is not found" do
    get "/maquina_stream/0/manifest"

    assert_response :not_found
  end

  test "the engine refuses when the host's authorization callable says no" do
    MaquinaStream.configure { |c| c.authorize = ->(_record, _request) { false } }

    get "/maquina_stream/#{messages(:streaming).id}/manifest"

    assert_response :forbidden
  end

  test "the engine refuses when the host configured no authorization at all" do
    MaquinaStream.configure { |c| c.authorize = nil }

    get "/maquina_stream/#{messages(:streaming).id}/manifest"

    assert_response :forbidden
  end
end
