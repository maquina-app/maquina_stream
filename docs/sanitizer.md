# Sanitizer

```ruby
MaquinaStream::Sanitizer.call(html, config: MaquinaStream.config) # => String
```

The last pass in the render chain (`maquina_remend → CommonMarker → Nokogiri
post-pass → Sanitizer`) and the only one that assumes the document is hostile.
It runs unconditionally: there is no mode, no flag and no fast path that skips
it. The buffer it protects is model output, which is prompt-injectable by
definition — a document that reached here having "already been checked" has not
been checked, it has been parsed.

It is a pure function. No Rails, no request, no ActiveSupport: it loads with
`nokogiri`, `uri` and a `Configuration`.

## How it decides

Nokogiri's **HTML5** parser builds the tree (the HTML4 parser's error recovery
is nobody's browser, and a sanitizer that parses differently from the engine
that renders is a mutation XSS waiting for its input). The tree is then walked
once:

1. An element on `DROP_WITH_CONTENT` — or in the SVG/MathML namespace — is
   removed **with its subtree**.
2. An element not on `ALLOWED_ELEMENTS` is **unwrapped**: the element goes, its
   sanitized children stay. Text survives; markup does not.
3. On a surviving element, each attribute must be named by the allowlist.
   Everything else is dropped, not escaped and kept.
4. `href` and `src` are re-parsed and re-checked (below). A rejected `href`
   leaves a link with its text; a rejected `src` removes the `<img>` entirely.
5. Comments, processing instructions and doctypes are removed. CDATA becomes
   text.

## What is allowed

**Elements** — rendered markdown plus the post-pass wrappers: headings, `p`,
`div`, `span`, `br`, `hr`, lists (`ul ol li dl dt dd`), tables (`table thead
tbody tfoot tr td th caption colgroup col`), `pre code kbd samp var`,
`blockquote figure figcaption details summary section article aside`, `a`,
`img`, the inline set (`em strong b i u s del ins mark small sub sup q abbr dfn
cite time wbr`) and `input` — the last one only as the tasklist extension's
checkbox, which is forced `disabled`.

**Attributes**

| Scope | Allowed |
|---|---|
| Global | `id class title lang dir role translate`, plus `aria-*` |
| `a` | `href target rel hreflang type` |
| `img` | `src alt width height loading decoding` |
| Lists / tables | `start reversed type value colspan rowspan align valign headers scope abbr span` |
| `time`, `details` | `datetime`, `open` |
| Ours | every `data-ms-*`, plus `data-component data-variant data-size data-slot data-state data-side data-orientation data-controller data-action data-turbo-permanent data-turbo-temporary` |

`data-controller` and `data-action` are filtered by **value**: only `ms-`
identifiers survive, and only action descriptors that name one. A third-party
controller's `data-<name>-*-value` attributes are dropped with it, so an
injected controller arrives with no configuration.

Anchors keep `target` normalized to `_blank`/`_self` and always gain
`rel="noopener noreferrer"`.

## What is dropped

- Every `on*` attribute, whatever its case, and whatever the parser made of a
  name split across a newline.
- `srcdoc`, `formaction`, `style`, `action`, `http-equiv`, `background`,
  `ping`, `srcset`, `usemap`, `name`, `contenteditable`, `accesskey`.
- Every namespaced attribute — `xlink:href`, `xml:base` — without exception. An
  allowlist for them would have to be a second allowlist.
- `script style svg math template noscript iframe object embed form button
  select textarea base link meta …`, each with its subtree. This includes the
  DOM contract's own `<script type="text/plain" data-ms-code-source>` carrier:
  the sanitizer cannot tell our carrier from an imitation of it, so it drops
  both. **A code block that needs its raw source in the DOM must carry it on a
  non-script element.**

### URLs

Applied to `href` and `src`, in order:

1. Control characters and Unicode whitespace are stripped first, so the scheme
   tested is the scheme a browser would act on (`java\tscript:`, `java\nscript:`).
2. `//host`, `\\host`, `/\host` — protocol-relative in every spelling — are
   rejected.
3. The scheme is read from the raw value **and** from a decoded copy (HTML
   entities, then percent-encoding). `java&#115;cript:`, `&amp;#106;avascript:`,
   `%6Aavascript:`, `JaVaScRiPt:` all resolve to a scheme on `DANGEROUS_SCHEMES`
   and are rejected.
4. A scheme must appear in `config.allowed_protocols` (default `http https
   mailto`). `data:` is special-cased: image positions only, only when
   `config.allow_data_images`, and only base64 raster types — `data:image/svg+xml`
   is a scriptable document wearing an image's MIME type and never passes.
5. A relative URL is resolved against `config.default_origin` when one is set,
   and the result must still be on an allowed protocol. With no origin set it is
   left as written. A bare `#fragment` is always kept.
6. The final URL must start with one of `config.allowed_link_prefixes` /
   `allowed_image_prefixes`. `["*"]` (the default) means any.

## Extending the allowlist

Everything lives in constants at the top of
`lib/maquina_stream/sanitizer.rb`:

- a new element → `ALLOWED_ELEMENTS`, or `DROP_WITH_CONTENT` if its contents
  must not survive it;
- a new attribute → `GLOBAL_ATTRIBUTES` or the element's entry in
  `ELEMENT_ATTRIBUTES`;
- a new hook of ours → name it `data-ms-*` and it is already allowed;
- a new URL-bearing attribute → give it a branch in `scrub_attribute_value`
  that runs it through `safe_url`, never a bare entry in the allowlist. An
  unhardened URL attribute is the whole bug.

Every change comes with a corpus file. `test/fixtures/xss/*.txt` holds one
attack per file:

```
--- input
<a href="javascript:alert(1)">clic</a>
--- note
javascript: link. The anchor text survives; the href must be dropped.
```

`test/maquina_stream/sanitizer_test.rb` turns each file into its own test case
at load time — adding a file adds a test, with no edit to the suite and no way
to add an attack that is quietly not run. Every entry is asserted to produce no
script element, no `on*` attribute, no forbidden attribute and no dangerous URL
scheme, and to be a fixed point under a second sanitization pass.

## Why the client sanitizes again

The server pass proves one thing: the HTML **we** serialize is safe. It cannot
speak for HTML the browser builds afterwards.

- Client-deferred renderers (`ms-diagram`, `ms-math`) receive a JSON payload
  and produce new DOM from it. The payload is attacker-influenced text that
  passed through here as an attribute *value*, never as markup — its output has
  never been sanitized by anyone until the controller does it. Mermaid runs in
  strict mode and its SVG is sanitized before insertion; KaTeX runs with trust
  disabled.
- `data-controller` is an allowlisted attribute. The sanitizer restricts it to
  our own `ms-` namespace, but it cannot tell a controller our post-pass emitted
  from one an injected fragment asked for. Every `ms-` controller must therefore
  treat its own values as untrusted input rather than as server intent.
- Serialize-and-reparse is where mutation XSS lives. Two parsers, two rounds of
  entity decoding, and one namespace boundary are enough to turn inert text into
  markup. A second pass at the point of insertion is cheap; being wrong once is
  not.

Server-side escaping protects the attribute boundary. It does not protect
whatever the client does with the value inside it.
