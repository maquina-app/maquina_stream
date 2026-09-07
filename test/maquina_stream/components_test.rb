# frozen_string_literal: true

require "test_helper"

class MaquinaStream::ComponentsTest < ActiveSupport::TestCase
  # A seam, not a mock: the resolver takes the library it probes, so both sides
  # of the branch are reachable without touching the load path.
  FakeLibrary = Struct.new(:names) do
    def defines?(name) = names.include?(name.to_sym)
  end

  ENGINE_ROOT = Pathname(File.expand_path("../..", __dir__))

  # Files that are allowed to name a component partial path: the seam itself.
  SEAM_FILES = [
    "lib/maquina_stream/components.rb",
    "app/helpers/maquina_stream/components_helper.rb",
    "test/maquina_stream/components_test.rb"
  ].freeze

  PARTIAL_PATH = %r{maquina_stream/components/|maquina_components/}

  setup { MaquinaStream::Components.reset_library! }
  teardown { MaquinaStream::Components.reset_library! }

  # ---------------------------------------------------------------- resolution

  test "resolves to maquina_components when the gem defines the component" do
    library = FakeLibrary.new(%i[code_block])

    assert_equal "maquina_components/code_block",
      MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config, library: library)
  end

  test "resolves to the vendored partial when the gem is absent" do
    assert_equal "maquina_stream/components/code_block",
      MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config, library: nil)
  end

  test "resolves to the vendored partial when the gem is present but does not define the component" do
    library = FakeLibrary.new(%i[card badge])

    assert_equal "maquina_stream/components/code_block",
      MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config, library: library)
  end

  test "config.components = :plain forces the vendored partial" do
    MaquinaStream.config.components = :plain
    library = FakeLibrary.new(%i[code_block snippet])

    assert_equal "maquina_stream/components/code_block",
      MaquinaStream::Components.partial_for(:code_block, config: MaquinaStream.config, library: library)
  end

  test "engine-owned components never resolve to the gem" do
    library = FakeLibrary.new(%i[shimmer source_citation])

    MaquinaStream::Components::ENGINE_OWNED.each do |name|
      assert_equal "maquina_stream/components/#{name}",
        MaquinaStream::Components.partial_for(name, config: MaquinaStream.config, library: library)
    end
  end

  test "vendored? marks only the extraction candidates" do
    assert MaquinaStream::Components.vendored?(:code_block)
    assert MaquinaStream::Components.vendored?(:snippet)
    refute MaquinaStream::Components.vendored?(:shimmer)
    refute MaquinaStream::Components.vendored?(:source_citation)

    assert MaquinaStream::Components.engine_owned?(:shimmer)
    assert MaquinaStream::Components.engine_owned?(:source_citation)
  end

  # ---------------------------------------------------------------- stylesheets

  test "one stylesheet per vendored component, and it exists" do
    MaquinaStream::Components.styled_components.each do |name|
      path = ENGINE_ROOT.join("app/assets/stylesheets/maquina_stream/components/#{name}.css")

      assert_predicate path, :exist?, "expected a stylesheet for #{name}"
    end

    assert_includes MaquinaStream::Components.styled_components, :code_block
    assert_includes MaquinaStream::Components.styled_components, :shimmer
  end

  test "a component the gem serves loads no stylesheet of ours" do
    with_gem = MaquinaStream::Components.stylesheets(
      config: MaquinaStream.config, library: FakeLibrary.new(%i[code_block snippet])
    )
    without_gem = MaquinaStream::Components.stylesheets(config: MaquinaStream.config, library: nil)

    assert_includes without_gem, "maquina_stream/components/code_block"
    refute_includes with_gem, "maquina_stream/components/code_block"
    refute_includes with_gem, "maquina_stream/components/snippet"

    # Engine-owned CSS is always ours to load.
    assert_includes with_gem, "maquina_stream/components/shimmer"
  end

  # ------------------------------------------------------------- the seam holds

  test "no engine code renders a component partial directly" do
    violations = direct_partial_references(ENGINE_ROOT, except: SEAM_FILES)

    assert_empty violations,
      "these files name a component partial path directly; render through " \
      "`component(:name, …)` instead:\n#{violations.join("\n")}"
  end

  test "the direct-render check actually fails when the seam is broken" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      root.join("app/views/maquina_stream").mkpath
      root.join("app/views/maquina_stream/_offender.html.erb")
          .write(%(<%= render "maquina_stream/components/shimmer" %>\n))
      root.join("app/views/maquina_stream/_innocent.html.erb")
          .write(%(<%= component(:shimmer) %>\n))

      violations = direct_partial_references(root, except: [])

      assert_equal ["app/views/maquina_stream/_offender.html.erb"], violations
    end
  end

  test "every vendored partial carries the extraction header and a locals line" do
    MaquinaStream::VENDORED_COMPONENTS.each do |name|
      path = ENGINE_ROOT.join("app/views/maquina_stream/components/_#{name}.html.erb")
      next unless path.exist? # not every candidate is built yet

      source = path.read

      assert_includes source,
        "<%# EXTRACTION CANDIDATE → maquina_components. See docs/component-scope.md %>",
        "#{name} is missing the extraction header"
      assert_match(/<%# locals: \(/, source, "#{name} is missing its locals line")
      refute_match(/\bclass:/, source.lines.grep(/<%# locals:/).join,
        "#{name} must take css_classes:, not class:")
      assert_match(/\*\*html_options/, source, "#{name} must accept **html_options")
    end
  end

  test "engine-owned partials are not labelled extraction candidates" do
    MaquinaStream::Components::ENGINE_OWNED.each do |name|
      source = ENGINE_ROOT.join("app/views/maquina_stream/components/_#{name}.html.erb").read

      refute_includes source, "EXTRACTION CANDIDATE"
      assert_includes source, "Engine-owned, permanent"
    end
  end

  test "data-component values use destination names, never ms- prefixed ones" do
    sources = Pathname.glob(ENGINE_ROOT.join("app/views/maquina_stream/components/_*.html.erb")).map(&:read)

    sources.each do |source|
      refute_match(/component: "ms-/, source)
      refute_match(/data-component="ms-/, source)
    end

    assert_equal %w[attachment code-block shimmer snippet source-citation suggestion],
      sources.flat_map { |s| s.scan(/component: "([a-z-]+)"/) }.flatten.sort
  end

  test "shimmer is the only skeleton" do
    others = Pathname.glob(ENGINE_ROOT.join("app/views/**/*.erb")).reject do |path|
      path.basename.to_s == "_shimmer.html.erb"
    end

    others.each do |path|
      refute_match(/animate-pulse|skeleton|placeholder-block/, path.read,
        "#{path} carries ad-hoc placeholder markup; render the shimmer component instead")
    end
  end

  private
    def direct_partial_references(root, except:)
      Pathname.glob(root.join("{app,lib}/**/*.{rb,erb}")).filter_map do |path|
        relative = path.relative_path_from(root).to_s
        next if except.include?(relative)
        next unless path.read.match?(/(?:render|partial)\b[^\n]*#{PARTIAL_PATH}/)

        relative
      end.sort
    end
end

# Renders through the engine's own view context — the same object the render
# pipeline uses — so these assertions are about the markup that actually ships,
# and so template compilation happens in one place for the whole suite.
class MaquinaStream::ComponentPartialsTest < ActiveSupport::TestCase
  setup { MaquinaStream::Components.reset_library! }

  private
    # The view is where the seam's helper lives; `component` is a helper, so
    # exercising it means calling it on a view.
    def view
      MaquinaStream::Renderer::ViewContext.build.send(:view)
    end

    def component(name, **locals)
      view.component(name, **locals)
    end

  public

  test "code_block emits the documented DOM contract" do
    html = component(:code_block, lang: "ruby", source: "puts 1", highlighted: nil)

    assert_includes html, "data-ms-code "
    assert_includes html, %(data-component="code-block")
    assert_includes html, %(data-ms-code-lang="ruby")
    assert_match(%r{<pre[^>]*><code[^>]*>puts 1</code></pre>}, html)
    assert_match(%r{<pre hidden data-ms-code-source>puts 1</pre>}, html)
  end

  test "code_block renders highlighted html when the fence has closed, and never highlights itself" do
    highlighted = %(<span class="k">puts</span> 1).html_safe
    html = component(:code_block, lang: "ruby", source: "puts 1", highlighted: highlighted)

    assert_includes html, %(<span class="k">puts</span> 1)
    # The raw source still travels verbatim for the copy button.
    assert_includes html, %(<pre hidden data-ms-code-source>puts 1</pre>)
  end

  # The carrier is <pre hidden>, not <script type="text/plain">. A script
  # carrier needs an exception in the sanitizer, and its content is serialized
  # unescaped - so a fence containing "</script><img>" breaks out on the next
  # parse. Ordinary escaped text in a <pre> needs no exception and nothing has
  # to be reversed when the copy button reads it back.
  test "raw source cannot break out of its carrier" do
    source = %(x = "</script><img src=x onerror=alert(1)>")
    html = component(:code_block, lang: "html", source: source)
    fragment = Nokogiri::HTML5.fragment(html)

    assert_nil fragment.at_css("img"), "the source escaped its carrier and became an element"
    assert_empty fragment.css("script")

    carrier = fragment.at_css("[data-ms-code-source]")

    assert_equal source, carrier.text, "the source must travel verbatim for copy and download"
  end

  test "caller data attributes merge, the component keeps its identity keys" do
    html = component(:code_block, source: "x", data: { controller: "analytics", testid: "cb" })

    assert_includes html, %(data-component="code-block")
    assert_includes html, %(data-testid="cb")
    assert_match(/data-controller="[^"]*analytics/, html)

    # A caller cannot steal the identity key the CSS selects on.
    overridden = component(:code_block, source: "x", data: { component: "not-a-code-block" })

    assert_includes overridden, %(data-component="code-block")
    refute_includes overridden, "not-a-code-block"
  end

  test "css_classes adds to the component's classes and does not replace them" do
    html = component(:code_block, source: "x", css_classes: "mt-8")

    assert_match(/class="[^"]*ms-code-block[^"]*mt-8/, html)
  end

  test "snippet carries the command and a copy affordance" do
    html = component(:snippet, command: "bin/rails maquina_stream:install", label: "Instalar")

    assert_includes html, %(data-component="snippet")
    assert_includes html, %(data-snippet-part="command")
    assert_includes html, %(data-snippet-part="copy")
    assert_includes html, "bin/rails maquina_stream:install"
  end

  test "shimmer renders a busy skeleton with the requested number of lines" do
    html = component(:shimmer, lines: 4)

    assert_includes html, %(data-component="shimmer")
    assert_includes html, %(aria-busy="true")
    assert_equal 4, html.scan(%(data-shimmer-part="line")).size
  end

  test "source_citation renders a link when the host resolved one" do
    html = component(:source_citation, id: "123", title: "Informe anual", href: "https://example.com/a", index: 1)

    assert_includes html, %(data-component="source-citation")
    assert_includes html, %(data-ms-source-id="123")
    assert_includes html, %(href="https://example.com/a")
    assert_includes html, "Informe anual"
  end

  test "source_citation still renders when nothing resolved" do
    html = component(:source_citation, id: "999")

    assert_includes html, %(data-component="source-citation")
    assert_includes html, "999"
    refute_includes html, "<a"
  end

  # ------------------------------------------------------------------ attachment

  # The locals are ActiveStorage's attribute names. If this test ever starts
  # reading `message.parts` or a `file` object, the AI SDK's client data model
  # has been imported and the server-rendered decision has been lost.
  test "attachment renders from ActiveStorage attributes" do
    html = component(:attachment,
      filename: "informe.pdf", byte_size: 20_480, content_type: "application/pdf",
      url: "https://example.com/informe.pdf")

    assert_includes html, %(data-component="attachment")
    assert_includes html, %(data-attachment-part="filename")
    assert_includes html, "informe.pdf"
    assert_includes html, "application/pdf"
    assert_includes html, "20"
    assert_includes html, %(data-attachment-part="download")
  end

  test "attachment has grid, inline and list variants" do
    %i[grid inline list].each do |variant|
      html = component(:attachment, filename: "a.txt", variant: variant, content_type: "text/plain")

      assert_includes html, %(data-variant="#{variant}")
      assert_includes html, "ms-attachment--#{variant}"
    end
  end

  test "attachment defaults to the grid variant" do
    assert_includes component(:attachment, filename: "a.txt"), %(data-variant="grid")
  end

  test "an image attachment shows a thumbnail and exposes the failure hook" do
    html = component(:attachment,
      filename: "foto.png", content_type: "image/png",
      url: "https://example.com/foto.png", preview_url: "https://example.com/foto-thumb.png")

    assert_includes html, %(data-attachment-part="thumbnail")
    assert_includes html, "foto-thumb.png"
    # The download control is hideable: it is a target of the same controller
    # the thumbnail reports its error to.
    assert_match(/data-controller="[^"]*ms-attachment/, html)
    assert_includes html, %(data-action="error->ms-attachment#thumbnailFailed")
    assert_includes html, %(data-ms-attachment-target="download")
  end

  test "a non-image attachment needs no controller at all" do
    html = component(:attachment, filename: "a.zip", content_type: "application/zip", url: "/a.zip")

    refute_includes html, "ms-attachment#"
    assert_includes html, %(data-attachment-part="icon")
  end

  # The size is formatted here rather than by number_to_human_size: ActiveSupport
  # ships English only, so the default locale would have no units to name.
  test "byte_size renders human readable, in the reader's locale" do
    I18n.with_locale(:es) do
      assert_includes component(:attachment, filename: "a", byte_size: 512), "512 B"
      assert_includes component(:attachment, filename: "a", byte_size: 1_536), "1,5 kB"
      assert_includes component(:attachment, filename: "a", byte_size: 5_242_880), "5,0 MB"
    end

    I18n.with_locale(:en) do
      assert_includes component(:attachment, filename: "a", byte_size: 1_536), "1.5 kB"
    end
  end

  test "component labels come from the locale files, not from the templates" do
    es = I18n.with_locale(:es) { component(:attachment, filename: "a.pdf", url: "/a.pdf") }
    en = I18n.with_locale(:en) { component(:attachment, filename: "a.pdf", url: "/a.pdf") }

    assert_includes es, "Descargar"
    assert_includes en, "Download"
  end

  test "a model-supplied filename cannot inject markup" do
    html = component(:attachment, filename: %(<img src=x onerror=alert(1)>.png), url: "/x")

    refute_includes html, "<img src=x"
    assert_includes html, "&lt;img"
  end

  test "the attachment download control is individually disableable" do
    MaquinaStream.config.controls = { attachment: { download: false } }
    html = component(:attachment, filename: "a.pdf", url: "/a.pdf")

    refute_includes html, %(data-attachment-part="download")
    # and nothing else went with it
    assert_includes html, "a.pdf"
  end

  test "remove is a DELETE the host opted into by passing a path" do
    html = component(:attachment, filename: "a.pdf", url: "/a.pdf", remove_path: "/attachments/9")

    assert_includes html, %(data-attachment-part="remove")
    assert_includes html, %(name="_method" value="delete")

    refute_includes component(:attachment, filename: "a.pdf", url: "/a.pdf"),
      %(data-attachment-part="remove"), "no remove path means no remove control"

    MaquinaStream.config.controls = { attachment: { remove: false } }
    refute_includes component(:attachment, filename: "a.pdf", url: "/a.pdf", remove_path: "/attachments/9"),
      %(data-attachment-part="remove")
  end

  # ------------------------------------------------------------------ suggestion

  test "suggestion renders a chip row of links, with no controller" do
    html = component(:suggestion, items: [
      { text: "Resume el hilo", href: "/prompts?q=1" },
      { text: "Dame un ejemplo", href: "/prompts?q=2" }
    ])

    assert_includes html, %(data-component="suggestion")
    assert_equal 2, html.scan(%(data-suggestion-part="chip")).size
    assert_includes html, "Resume el hilo"
    refute_includes html, "data-controller"
  end

  test "a suggestion chip can be a form submission the host supplied" do
    html = component(:suggestion, items: [
      { text: "Reintentar", href: "/prompts", method: :post, params: { prompt: "Reintentar" } }
    ])

    assert_match(/<form[^>]*method="post"/, html)
    assert_includes html, %(value="Reintentar")
  end

  test "suggestion skips empty chips and renders nothing at all when it has none" do
    html = component(:suggestion, items: [{ text: "", href: "/a" }, { href: "/b" }])

    assert_equal "", html.strip
  end

  test "the suggestion row is disableable wholesale" do
    MaquinaStream.config.controls = { suggestion: { enabled: false } }

    assert_equal "", component(:suggestion, items: [{ text: "Hola", href: "/a" }]).strip
  end

  test "every control off is one expression" do
    MaquinaStream.config.controls = false

    assert_equal "", component(:suggestion, items: [{ text: "Hola", href: "/a" }]).strip
    refute_includes component(:attachment, filename: "a.pdf", url: "/a.pdf"),
      %(data-attachment-part="download")
  end

  test "a model-supplied citation title cannot inject markup" do
    html = component(:source_citation, id: "1", title: %(<img src=x onerror=alert(1)>))

    refute_includes html, "<img"
    assert_includes html, "&lt;img"
  end
end
