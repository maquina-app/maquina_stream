# frozen_string_literal: true

require "test_helper"

# History: a page of finished messages, and what makes it cheap.
class HistoryTest < ActionDispatch::IntegrationTest
  setup do
    MaquinaStream::ComponentCache.clear!
    MaquinaStream::ComponentCache.reset_stats!
  end

  # ------------------------------------------------------------------ caching

  test "a sealed message renders from cache on every load after the first" do
    message = messages(:sealed)
    message.update!(content: "# Uno\n\nDos.", stream_status: "complete")

    first = MaquinaStream.render(message)
    misses_after_first = MaquinaStream::ComponentCache.stats[:misses]

    3.times { assert_equal first, MaquinaStream.render(message) }

    assert_equal misses_after_first, MaquinaStream::ComponentCache.stats[:misses],
      "a sealed message is immutable; re-rendering it on every page load is work nobody asked for"
  end

  test "an open message is never cached, because it is about to change" do
    message = messages(:streaming)
    message.update!(content: "a medias", stream_status: "open")

    size_before = MaquinaStream::ComponentCache.size
    2.times { MaquinaStream.render(message) }

    assert_equal size_before, MaquinaStream::ComponentCache.size,
      "an open message must not be cached at all; it would serve a stale frame"

    message.update!(content: "a medias, y más")

    assert_includes MaquinaStream.render(message), "y más"
  end

  test "editing a sealed message invalidates its cached render" do
    message = messages(:sealed)
    message.update!(content: "original", stream_status: "complete")
    before = MaquinaStream.render(message)

    message.update!(content: "corregido")

    refute_equal before, MaquinaStream.render(message),
      "the cache key is the buffer digest, so an edit is a different key"
    assert_includes MaquinaStream.render(message), "corregido"
  end

  # --------------------------------------------------------------- pagination

  test "history renders a page of messages, newest last" do
    create_history(25)

    get "/history"

    assert_response :success
    assert_select "[data-history-part=message]", 10
  end

  test "history offers a lazy frame for the messages above" do
    create_history(25)

    get "/history"

    assert_select "turbo-frame[loading=lazy][src*='before=']", 1,
      "history loads upward on scroll, not through a pagination bar"
  end

  test "following the frame returns the page above, not the same page" do
    create_history(25)

    get "/history"
    first_page_ids = css_select("[data-history-part=message]").map { |node| node["id"] }
    src = css_select("turbo-frame[loading=lazy]").first["src"]

    get src
    older_ids = css_select("[data-history-part=message]").map { |node| node["id"] }

    assert_response :success
    refute_empty older_ids
    assert_empty older_ids & first_page_ids, "the frame served messages the reader already had"
  end

  test "the topmost page offers no further frame" do
    create_history(8)

    get "/history"

    assert_select "[data-history-part=message]", 8
    assert_select "turbo-frame[loading=lazy]", 0, "there is nothing above the first message"
  end

  private
    def create_history(count)
      Message.delete_all
      count.times do |n|
        Message.create!(content: "# Mensaje #{n}\n\nCuerpo #{n}.", stream_sequence: n, stream_status: "complete")
      end
    end
end
