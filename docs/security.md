# Security

Everything this engine renders is model output, and model output is
prompt-injectable by definition. A document that reached the sanitizer having
"already been checked" has not been checked — it has been parsed.

## The one rule for a host

**Never assign model output as raw HTML.**

The engine's own output is `html_safe` because it has been through the
sanitizer. Anything else — a buffer, a payload, a tool result, a value you read
back out of rendered markup in JavaScript — is not. Do not `html_safe` it, do
not `innerHTML` it, do not hand it to a template that will.

```erb
<%= MaquinaStream.render(message) %>          <%# sanitized on the way out %>
<%= raw message.content %>                    <%# never %>
```

## The sanitizer

```ruby
MaquinaStream::Sanitizer.call(html, config: MaquinaStream.config) # => String
```

It is the last pass in the render chain — `maquina_remend → CommonMarker →
Nokogiri post-pass → Sanitizer` — and the only one that assumes the document is
hostile. It runs unconditionally: no mode, no flag, no fast path skips it. It is
a pure function, with no Rails and no request.

Nokogiri's **HTML5** parser builds the tree, because a sanitizer that parses
differently from the engine that will render the output is a mutation-XSS bug
waiting for its input.

```
in : <a href="javascript:alert(1)">clic</a>
out: <a>clic</a>

in : <img src="x" onerror="alert(1)">
out: <img src="x">

in : <script>alert(1)</script>hola
out: hola
```

### How it decides

1. An element on the drop list — or in the SVG or MathML namespace — is removed
   **with its subtree**.
2. An element not on the allowlist is **unwrapped**: the element goes, its
   sanitized children stay. Text survives; markup does not.
3. On a surviving element, each attribute must be named by the allowlist.
   Everything else is dropped, not escaped and kept.
4. `href` and `src` are re-parsed and re-checked. A rejected `href` leaves the
   link with its text; a rejected `src` removes the `<img>` entirely, because a
   broken rectangle carrying an attacker-chosen `alt` is worse than nothing.
5. Comments, processing instructions and doctypes are removed. CDATA becomes
   text.

### What survives

**Elements** — rendered markdown plus the post-pass wrappers: headings, `p`,
`div`, `span`, `br`, `hr`, lists (`ul ol li dl dt dd`), tables
(`table thead tbody tfoot tr td th caption colgroup col`),
`pre code kbd samp var`, `blockquote figure figcaption details summary section
article aside`, `a`, `img`, the inline set (`em strong b i u s del ins mark
small sub sup q abbr dfn cite time wbr`), and `input` — the last only as the
tasklist checkbox, forced `disabled`.

**Attributes**

| Scope | Allowed |
|---|---|
| Global | `id class title lang dir role translate`, plus `aria-*` |
| `a` | `href target rel hreflang type` |
| `img` | `src alt width height loading decoding` |
| Lists and tables | `start reversed type value colspan rowspan align valign headers scope abbr span` |
| `time`, `details` | `datetime`, `open` |
| The engine's | every `data-ms-*`, plus `data-component data-variant data-size data-slot data-state data-side data-orientation data-controller data-action data-turbo-permanent data-turbo-temporary` |

`data-controller` and `data-action` are filtered **by value**: only `ms-`
identifiers survive, and only action descriptors naming one. A third-party
controller's `data-<name>-*-value` attributes are dropped with it, so an
injected controller arrives with no configuration:

```
in : <div data-controller="evil" data-evil-url-value="x">hi</div>
out: <div>hi</div>
```

Anchors keep `target` normalized to `_blank`/`_self` and always gain
`rel="noopener noreferrer"`.

### What is dropped

- Every `on*` attribute, whatever its case, and whatever the parser made of a
  name split across a newline.
- `srcdoc`, `formaction`, `style`, `action`, `http-equiv`, `background`, `ping`,
  `srcset`, `usemap`, `name`, `contenteditable`, `accesskey`.
- Every namespaced attribute — `xlink:href`, `xml:base` — without exception.
- `script style svg math template noscript iframe object embed form button
  select textarea base link meta …`, each with its subtree.

That last one includes any `<script type="text/plain">` carrier: the sanitizer
cannot tell yours from an imitation of it, and Nokogiri's HTML5 serializer
writes script children unescaped, so a fence containing
`</script><img onerror=…>` would break out on the next parse. **A code block
that needs its raw source in the DOM must carry it on a non-script element** —
which is why the engine's carrier is a `<pre hidden data-ms-code-source>`.

### URL hardening

Applied to `href` and `src`, in order:

1. Control characters and Unicode whitespace are stripped first, so the scheme
   tested is the scheme a browser would act on (`java\tscript:`,
   `java\nscript:`).
2. `//host`, `\\host`, `/\host` — protocol-relative in every spelling — are
   rejected.
3. The scheme is read from the raw value **and** from a decoded copy (HTML
   entities, then percent-encoding). `java&#115;cript:`, `&amp;#106;avascript:`,
   `%6Aavascript:` and `JaVaScRiPt:` all resolve to a dangerous scheme and are
   rejected.
4. The scheme must appear in `config.allowed_protocols` (default `http https
   mailto`).
5. A relative URL is resolved against `config.default_origin` when one is set,
   and the result must still be on an allowed protocol. With no origin set it is
   left as written. A bare `#fragment` is always kept.
6. The final URL must start with one of `config.allowed_link_prefixes` /
   `allowed_image_prefixes`. `["*"]`, the default, means any.

`data:` is special-cased: image positions only, only when
`config.allow_data_images`, and only base64 raster types.

```
allow_data_images = true   <img src="data:image/png;base64,iVBORw0KGgo=">  → kept
allow_data_images = false  <img src="data:image/png;base64,iVBORw0KGgo=">  → removed
either                     <img src="data:image/svg+xml;base64,…">         → removed
```

`data:image/svg+xml` is a scriptable document wearing an image's MIME type and
never passes, whatever you configure.

Tightening the two prefix lists is the main lever you have over what a model may
link to. See [configuration.md](configuration.md).

## The markdown normalisation pass

One pass runs between `maquina_remend` and the markdown parser, and it can only
insert newlines: around the opening and closing tags of tags you registered with
`register_tag`, so a block-level `<thinking>` parses as its own HTML block
instead of leaving a stray end tag inside a paragraph. Without it, the parser
never closes the element and the rest of the message is handed to your partial.

It is deliberately narrow, because it changes how model-written text is parsed:

- The allowlist is your `register_tag` registry. An unregistered tag is never
  matched and never moved.
- Fenced blocks and inline code win — matching runs over masked text, so a
  registered name inside them is content.
- CommonMark's raw HTML regions — comments, `<script>`, `<pre>`, `<style>`,
  `<textarea>`, CDATA, processing instructions — are masked too. A blank line
  inserted inside one of those would end it early and publish what it hid.
- Indented code is excluded by an indent rule.
- A match must be a complete, well-formed tag on one line, parsed with
  CommonMark's attribute grammar, so a `>` inside a quoted value cannot make an
  insertion land mid-tag.

Because it only inserts newlines, it can promote model text from raw HTML into
markdown, or split a paragraph — but it cannot introduce an element or an
attribute the allowlist does not name. The sanitizer runs unconditionally,
last, over the parsed HTML. The whole XSS corpus is additionally run through the
renderer with tags registered.

## Why the client sanitizes again

The server pass proves one thing: the HTML **the engine** serializes is safe. It
cannot speak for HTML the browser builds afterwards.

- Client-deferred renderers (`ms-diagram`, `ms-math`) receive a JSON payload and
  produce new DOM from it. That payload is attacker-influenced text which passed
  through the sanitizer as an attribute *value*, never as markup — nothing has
  sanitized its output until the controller does. So `ms-deferred` applies its
  own allowlist to whatever the library returns.
- `data-controller` is an allowlisted attribute. The sanitizer restricts it to
  the `ms-` namespace, but cannot tell a controller the post-pass emitted from
  one an injected fragment asked for. Every `ms-` controller therefore treats its
  own values as untrusted input rather than as server intent.
- Serialize-and-reparse is where mutation XSS lives. Two parsers, two rounds of
  entity decoding and one namespace boundary are enough to turn inert text into
  markup.

Server-side escaping protects the attribute boundary. It does not protect
whatever the client does with the value inside it.

## Renderer posture

| Renderer | Setting | What it buys |
|---|---|---|
| `ms-diagram` (Mermaid) | `securityLevel: "strict"` | disables click handlers and inline HTML in diagram source |
| `ms-math` (KaTeX) | `trust: false` | refuses `\htmlClass`, `\includegraphics` and `\href`, all of which take attacker-controlled strings into the DOM |
| both | output allowlist | the library is third-party; its output is scrubbed before it reaches the DOM |

## Limits

- **It sanitizes HTML, not meaning.** A model that writes a plausible phishing
  link to an allowed host produces a link the sanitizer will happily keep. That
  is what `allowed_link_prefixes` and the link-safety dialog are for.
- **A registered partial is yours to get right.** Registry output still goes
  through the sanitizer, so it cannot introduce an element or attribute the
  allowlist does not name — but a partial that renders an attacker-supplied
  string into an allowed attribute is a hole the allowlist cannot see.
- **Your own controllers are outside its reach.** A controller of yours that
  reads a value out of rendered markup and assigns it as HTML has undone the
  whole chain.
- **The broadcast target is yours.** The sanitizer has nothing to say about who
  may subscribe to a Turbo stream.

## Extending the allowlist

Everything lives in constants at the top of `lib/maquina_stream/sanitizer.rb`:

- a new element → `ALLOWED_ELEMENTS`, or `DROP_WITH_CONTENT` if its contents
  must not survive it;
- a new attribute → `GLOBAL_ATTRIBUTES`, or the element's entry in
  `ELEMENT_ATTRIBUTES`;
- a new hook of your own → name it `data-ms-*` and it is already allowed;
- a new URL-bearing attribute → give it a branch in `scrub_attribute_value` that
  runs it through `safe_url`, never a bare entry in the allowlist. An unhardened
  URL attribute is the whole bug.

Every change comes with a corpus file. `test/fixtures/xss/*.txt` holds one
attack per file:

```
--- input
<a href="javascript:alert(1)">clic</a>
--- note
javascript: link. The anchor text survives; the href must be dropped.
```

The suite turns each file into its own test case at load time, so adding a file
adds a test and there is no way to add an attack that is quietly not run. Every
entry is asserted to produce no script element, no `on*` attribute, no forbidden
attribute and no dangerous URL scheme, and to be a fixed point under a second
sanitization pass.
