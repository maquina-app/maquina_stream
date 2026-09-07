# frozen_string_literal: true

# Browser fixture for the Phase 5 controllers. Test-only: nothing in the engine
# depends on it, and it is not mounted anywhere a host would see.
#
#   bin/rails server   (from test/dummy)  →  http://localhost:3000/harness
class HarnessController < ActionController::Base
  # For the backgrounded-tab check only. A browser throttles setInterval in a
  # hidden tab - Chrome to about once a minute - so a timer-driven harness stops
  # delivering the moment the reader looks away, and cannot ask what happens to
  # text that arrives while nobody is watching. Real frames do not arrive on a
  # timer; they are pushed by the server, and a push is delivered to a hidden
  # tab like any other. This streams them.
  include ActionController::Live

  layout "application"

  MARKDOWN = <<~'MD'
    # Test panel

    A paragraph with **bold** and an [external link](https://example.com/external).

    ```ruby
    def greet(name)
      puts "Hello, #{name}"
    end
    ```

    | Product | Price | Notes |
    |---|---|---|
    | Coffee | 3.50 | with "quotes" |
    | Tea | 2.00 | and, a comma |
  MD

  # A real, sealed record so ms-repair has genuine endpoints to talk to.
  REPAIRABLE = "# Report\n\nFirst paragraph, sealed.\n\nSecond paragraph, sealed.\n\nThird.\n\nFourth.\n"

  def repair
    @message = Message.find_or_create_by!(content: REPAIRABLE) do |m|
      m.stream_sequence = 7
      m.stream_status = "complete"
    end
    @message.update!(stream_status: "complete")
  end

  # Phase 6 DoD: heavy libraries load lazily, never on pages that don't need
  # them. /harness is the negative control — no deferred block, no library. This
  # page is the positive one, and the spacers are the whole point. Each block
  # starts far enough below the fold that the IntersectionObserver in
  # ms-deferred has not fired, and the two are separated from each other, so
  # every library fetch is attributable to one block scrolling into view. Side
  # by side they enter the viewport together and prove only that both loaded.
  DIAGRAM = <<~MD
    ```mermaid
    graph TD
      A[Question] --> B[Answer]
      B --> C[Citation]
    ```
  MD

  MATH = <<~MD
    ```math
    E = mc^2
    ```
  MD

  def deferred
    @diagram_html = MaquinaStream::Renderer.call(DIAGRAM, mode: :static)
    @math_html = MaquinaStream::Renderer.call(MATH, mode: :static)
  end

  # A block that wraps over several visual lines, which is the case the Phase 0
  # mask got wrong: a character fraction is not a horizontal position, so the
  # defect only shows once a block occupies more than one line.
  REVEAL = <<~MD
    First block, already on screen. This paragraph is deliberately long so that it
    occupies several visual lines when the container is narrow, because the defect
    this harness exists to catch only shows up once a block is spread over more
    than one line.

    Second block, also on screen.
  MD

  # Through Document, not Renderer: the reveal binds to `data-ms-block`, and
  # that is what stamps it.
  def reveal
    @html = MaquinaStream::Document.new(
      REVEAL, config: MaquinaStream.config, sid: "reveal", mode: :streaming
    ).blocks.map(&:html).join("\n").html_safe
  end

  # Server-sent events rather than Action Cable: the question here is only
  # whether the reveal replays text that arrived unseen, and SSE answers it with
  # no cable, no subscription and no channel in the way.
  def reveal_stream
    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"

    fragments = [
      "The report continues with one more sentence.",
      "Each fragment arrives the way a frame would.",
      "The text wraps over several visual lines.",
      "And so the tail grows while nobody is watching."
    ]

    40.times do |index|
      response.stream.write("data: #{fragments[index % fragments.length]} [#{index}]\n\n")
      sleep 0.45
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    # The reader closed the tab or navigated away. Nothing to do.
  ensure
    response.stream.close
  end

  def show
    @html = MaquinaStream::Renderer.call(MARKDOWN, mode: :static)
    @streaming_html = MaquinaStream::Renderer.call(MARKDOWN, mode: :streaming)
  end
end
