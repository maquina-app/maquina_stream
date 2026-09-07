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

  def show
    @html = MaquinaStream::Renderer.call(MARKDOWN, mode: :static)
    @streaming_html = MaquinaStream::Renderer.call(MARKDOWN, mode: :streaming)
  end
end
