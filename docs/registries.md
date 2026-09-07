# Registries

Three registries let you change what the pipeline renders without touching the
engine. All three are process-global and are read during the render post-pass,
so register from an initializer:

```ruby
# config/initializers/maquina_stream.rb
MaquinaStream.register_fence "ruby", strategy: :server
MaquinaStream.register_tag :source, attributes: %w[id href title], partial: "…"
MaquinaStream.register_element :h2, partial: "headings/h2"
```

Whatever a registration renders still goes through the sanitizer, which is the
last pass and has no exceptions. A registry cannot inject raw HTML into a
document. See [security.md](security.md).

`test/dummy/config/initializers/maquina_stream.rb` registers all of these, and
`test/maquina_stream/registries_example_test.rb` drives that registration
through the full pipeline. Copy from there.

## Fences

```ruby
MaquinaStream.register_fence "ruby", strategy: :server
MaquinaStream.register_fence "text", strategy: :passthrough
MaquinaStream.register_fence "mermaid", strategy: :client,
  controller: "ms-diagram",
  payload: ->(source, info) { {source: source, info: info} }
```

| Strategy | What it does | When to use it |
|---|---|---|
| `:server` | Rouge highlights the source once the fence closes, into CSS classes. The default for every unregistered language. | Anything Rouge has a lexer for. |
| `:client` | Nothing is rendered server-side. The block carries a `payload:` as a data attribute and a Stimulus `controller:` draws it in the browser. | Diagrams, math — anything whose renderer is a JavaScript library the server has no business running. |
| `:passthrough` | The source is emitted as escaped text and nothing else happens to it. | A language Rouge would mangle, or one whose highlighting is not worth the CPU. |

Two rules the pipeline enforces rather than trusts:

- **An open fence is never highlighted.** The work would be thrown away on the
  next frame, and it is the difference between a 500-line fence fitting in the
  frame budget and not. Do not expect syntax colours until the closing ``` lands.
- **A `:client` fence emits no payload until it closes.** Handing the client
  half a diagram to draw produces an error state for text that was merely still
  arriving. Until then it renders a `shimmer` skeleton.

### `:server`, closed

````markdown
```ruby
puts 1
```
````

```html
<div data-ms-code data-ms-code-lang="ruby" data-controller="ms-code" data-component="code-block" …>
  <div data-code-block-part="header">
    <span data-code-block-part="lang">ruby</span>
    <span data-code-block-part="controls">
      <button data-code-block-part="copy" data-ms-control data-action="ms-code#copy">Copiar</button>
      <button data-code-block-part="download" data-ms-control data-action="ms-code#download">Descargar</button>
    </span>
  </div>
  <pre data-code-block-part="pre"><code><span class="nb">puts</span> <span class="mi">1</span></code></pre>
  <pre hidden data-ms-code-source>puts 1
</pre>
</div>
```

The `<pre hidden data-ms-code-source>` carrier is what the copy and download
buttons read, so a copy hands back the raw source rather than Rouge's span
markup. It is a `<pre hidden>` and not a script tag on purpose: the sanitizer
drops every script element, and cannot tell our carrier from an imitation of it.

The same fence while still open renders the shell and the carrier, with no
highlighting spans and no control buttons.

### `:client`, closed

````markdown
```mermaid
graph TD; A-->B;
```
````

```html
<div data-controller="ms-diagram"
     data-ms-diagram-payload-value='{"source":"graph TD; A--\u003eB;\n","info":"mermaid"}'>
  <div data-ms-diagram-target="output" data-turbo-permanent>…shimmer…</div>
</div>
```

Split ownership: the payload attribute is server state and belongs to morph; the
output element is client state, is `data-turbo-permanent`, and belongs to the
controller. See [deferred-renderers.md](deferred-renderers.md).

While the fence is open there is no payload and no controller at all — only the
shimmer.

### `:passthrough`

````markdown
```text
as is
```
````

```html
<pre data-ms-element="pre"><code class="language-text">as is
</code></pre>
```

## Custom tags

Models emit XML-ish tags that mean something to your application rather than to
markdown: `<source>`, `<citation>`, `<thinking>`. Register one and the post-pass
replaces its node with your partial.

The reference case is a model citing its sources:

```ruby
MaquinaStream.register_tag :source,
  attributes: %w[id href title],
  partial: "maquina_stream/components/source_citation",
  literal_content: false
```

| Option | Meaning |
|---|---|
| `attributes:` | The attribute names the tag may carry. Anything else on it is dropped before the partial is called. |
| `partial:` | The partial that renders it. Registered attribute names arrive as locals, so they must match the locals it declares — `href`, not `url`. |
| `literal_content:` | `true` passes the tag's body as text; `false` renders it as markdown. |

```markdown
Según la fuente <source id="3" href="https://example.com/a" title="Un artículo" onclick="alert(1)"></source>.
```

```html
<p data-ms-element="p">Según la fuente <span data-component="source-citation" data-ms-source-id="3" …>
  <a data-source-citation-part="link" href="https://example.com/a" rel="noopener noreferrer">Un artículo</a>
</span>.</p>
```

`onclick` never reaches the partial at all — it is gone before the sanitizer is
even asked, because the registration did not list it.

### An unregistered tag does not survive; its content does

The sanitizer *unwraps* an element it does not know: the tag goes, its children
stay.

```markdown
text <danger id="1">content</danger> more
```

```html
<p data-ms-element="p">text content more</p>
```

Text stranded at the top level this way is wrapped into a `<p>` before the
document is split, so it lands in a block of its own with an id and a digest,
and morphs and repairs like any other block. Its id comes from the first free
index at or after its position, so ids stay unique but are not always in
ascending order.

Mid-stream this is stable. `maquina_remend` removes only a tag whose `>` has not
arrived yet (`"text <thinki"` → `"text"`), the sanitizer unwraps the tag whether
it closed or not, and closing the tag changes no block above it — so nothing
flickers and no sealed block is rewritten.

### Block-level tags

A registered tag can also wrap several paragraphs. The partial receives the
whole thing as its `content`, rendered as markdown:

```ruby
MaquinaStream.register_tag :thinking, attributes: [], partial: "tags/reasoning"
```

```erb
<%# app/views/tags/_reasoning.html.erb %>
<%# locals: (content: "") %>
<section data-ms-reasoning><%= content.to_s.html_safe %></section>
```

```markdown
<thinking>
One.

Two.
</thinking>

After.
```

```html
<section data-ms-reasoning id="ms-7-b0" data-ms-block data-ms-block-digest="434332299dedf830">
  <p data-ms-element="p">One.</p>
  <p data-ms-element="p">Two.</p>
</section>
<p id="ms-7-b1" data-ms-element="p" data-ms-block data-ms-block-digest="e44dfc18531833b6">After.</p>
```

Two things to know before you reach for this:

1. **The whole tag is one block.** Four paragraphs of reasoning are one id, one
   digest and one unit of repair — not four. If you want them to seal and
   repair separately, leave the tag unregistered and style the blocks instead.
2. **That block cannot seal until the tag closes**, so everything inside it is
   re-sent on every frame. A four-paragraph body costs about 30% more bytes on
   the wire than the same text unregistered; a twenty-paragraph body costs 3.5x,
   and the single block is 88% of it. Keep block-level tags short, or accept the
   cost at the tail.
3. **Only registered names are treated this way.** With an empty registry the
   buffer is untouched, and a `<thinking>` inside a fence or a backtick span
   stays text:

````markdown
```text
<thinking>x</thinking>
```
````

```html
<pre data-ms-element="pre"><code class="language-text">&lt;thinking&gt;x&lt;/thinking&gt;
</code></pre>
```

### Where block-level handling applies

Only to names you passed to `register_tag`, and only where the opening tag
begins a line under four columns of indent — the shape that starts an HTML
block. An inline `<citation>…</citation>` in the middle of a sentence is left
exactly as the model wrote it, because it already renders correctly.

It never applies inside a fenced code block, an inline code span, an indented
code block, an HTML comment, `<script>`, `<pre>`, `<style>`, `<textarea>`, CDATA
or a processing instruction — that text is content, not markup. A tag broken
across a newline, one whose `>` has not arrived, an opener with no closer, a
closer with no opener, and `<thinking/>` are all left alone.

One limitation follows from the indent rule: **a block-level registered tag
inside a list item is not supported.** Put it at the top level.

## Element overrides

Replace the markup the renderer produces for one element with a partial of your
own:

```ruby
MaquinaStream.register_element :h2, partial: "headings/h2"
```

The partial receives `content:` (the element's inner HTML) and `node:` (the
Nokogiri node), so it must declare both:

```erb
<%# app/views/headings/_h2.html.erb %>
<%# locals: (content: "", node: nil) %>
<h2 class="section-heading"><span aria-hidden="true">§</span> <%= content.to_s.html_safe %></h2>
```

```markdown
## Thinking
```

```html
<h2 class="section-heading"><span aria-hidden="true">§</span> Thinking<a href="#thinking" class="anchor" …></a></h2>
```

Registering the same element twice replaces the first registration; the last one
in wins. Elements you do not override carry `data-ms-element="<tag>"` as a
styling hook, which is usually enough — reach for an override when you need
different structure, not different CSS.

## Resetting

```ruby
MaquinaStream.reset_registries!
```

For tests. Called in production it loses every registration your initializer
made.
