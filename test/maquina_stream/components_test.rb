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

    assert_equal %w[code-block shimmer snippet source-citation],
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

  test "a model-supplied citation title cannot inject markup" do
    html = component(:source_citation, id: "1", title: %(<img src=x onerror=alert(1)>))

    refute_includes html, "<img"
    assert_includes html, "&lt;img"
  end
end
