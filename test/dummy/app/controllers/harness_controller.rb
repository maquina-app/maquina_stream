# frozen_string_literal: true

# Browser fixture for the Phase 5 controllers. Test-only: nothing in the engine
# depends on it, and it is not mounted anywhere a host would see.
#
#   bin/rails server   (from test/dummy)  →  http://localhost:3000/harness
class HarnessController < ActionController::Base
  layout "application"

  MARKDOWN = <<~'MD'
    # Panel de pruebas

    Un párrafo con **negrita** y un [enlace externo](https://example.com/externo).

    ```ruby
    def saludar(nombre)
      puts "Hola, #{nombre}"
    end
    ```

    | Producto | Precio | Notas |
    |---|---|---|
    | Café | 3,50 | con "comillas" |
    | Té | 2,00 | y, una coma |
  MD

  # A real, sealed record so ms-repair has genuine endpoints to talk to.
  REPAIRABLE = "# Informe\n\nPrimer párrafo, sellado.\n\nSegundo párrafo, sellado.\n\nTercero.\n\nCuarto.\n"

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
      A[Pregunta] --> B[Respuesta]
      B --> C[Cita]
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
    Primer bloque, ya en pantalla. Este párrafo es deliberadamente largo para que
    ocupe varias líneas visuales cuando el contenedor es estrecho, porque el
    defecto que este arnés existe para detectar sólo aparece cuando un bloque se
    reparte en más de una línea.

    Segundo bloque, también en pantalla.
  MD

  # Through Document, not Renderer: the reveal binds to `data-ms-block`, and
  # that is what stamps it.
  def reveal
    @html = MaquinaStream::Document.new(
      REVEAL, config: MaquinaStream.config, sid: "reveal", mode: :streaming
    ).blocks.map(&:html).join("\n").html_safe
  end

  def show
    @html = MaquinaStream::Renderer.call(MARKDOWN, mode: :static)
    @streaming_html = MaquinaStream::Renderer.call(MARKDOWN, mode: :streaming)
  end
end
