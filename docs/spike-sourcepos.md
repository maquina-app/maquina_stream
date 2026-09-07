# Spike: CommonMarker source positions

**Date:** 2026-09-06 · **Status:** resolved — no redesign, but **Decision 1 needs an amendment**: HTML blocks carry no `data-sourcepos`, so the splitter cannot assume the attribute is always there.
**Method:** source inspection of `gjtorikian/commonmarker` at `v2.10.0`, then **verified at runtime on 2026-09-06** against `commonmarker 2.10.0` (arm64-darwin, Ruby 4.0.0) by `test/sourcepos_test.rb`. Where the two disagree, the runtime findings below win.

## Question

Phase 3's block splitter depends on mapping parsed blocks back to line ranges of the raw buffer. CommonMarker 2.x moved from cmark-gfm to comrak, and the concern was that the node API had been dropped, which would have forced a structural pre-parse scan instead.

## Finding

Both routes exist and are healthy in 2.10.0.

### Route A — sourcepos on rendered HTML (preferred)

```ruby
Commonmarker.to_html(md, options: { render: { sourcepos: true } })
# => <p data-sourcepos="2:1-2:9">paragraph</p>
```

Confirmed in `test/sourcepos_test.rb`. Almost every block-level element carries `data-sourcepos="startLine:startCol-endLine:endCol"` — **HTML blocks do not**. See "Runtime findings", Q2.

This is better than the design assumed. The Nokogiri post-pass receives line ranges directly on the elements it is already walking — no separate AST traversal, and no correlation step between tree and output.

### Route B — node API (available, use where A is awkward)

`Commonmarker.parse(text)` returns a node tree. Bound node methods include:

> **Corrected 2026-09-06.** This section previously listed `get_sourcepos`, `get_fenced`, `get_fence_info`, `get_first_child`, `get_next_sibling`, `get_parent`, `type_to_symbol`, `get_literal` and `get_string_content`, read off the Rust binding source. **None of them exist on the Ruby object** — `refute_respond_to` passes on every one. The real Ruby API is:

`source_position` `fenced?` `fence_info` `first_child` `last_child` `next_sibling` `previous_sibling` `parent` `type` `literal` `string_content` `header_level` `list_type` `list_start` `list_tight` `url` `title` `to_html` `to_commonmark` `walk` `each`

`source_position` returns `{ start_line:, start_column:, end_line:, end_column: }`.

`fenced?` and `fence_info` give open-fence detection and the language string directly, which Phase 2 needs for the renderer-strategy registry and Phase 3 needs for deferred highlighting.

## Decisions this settles

1. **Block splitter uses Route A.** Walk top-level elements of the rendered HTML, read `data-sourcepos`, slice the raw buffer by line range. Strip the attribute in the same pass unless debugging.
   **Amended 2026-09-06:** this is not universal. An HTML block renders with **no** `data-sourcepos`, and a link reference definition renders no element at all. The walk must cope with an unattributed top-level element and with source lines no element claims. See Q2 below.
2. **Enable `parse: { sourcepos_chars: true }`.** comrak exposes this; it makes column numbers count characters rather than bytes. Ruby string slicing is character-based, so enabling it removes a whole class of off-by-N bug on multibyte content — which agent output contains constantly.
3. **Do not render blocks in isolation via `Node#to_html`.** Tempting for sealing, but a node rendered alone loses link reference definitions declared elsewhere in the document. Render the whole buffer and slice the output.

## Runtime findings (2026-09-06, commonmarker 2.10.0)

Backed by `test/sourcepos_test.rb` — 18 tests, 87 assertions, green under `bin/test`.

### Q1 — Does an unterminated fenced code block report a `sourcepos` end line? **Yes.**

```
"```ruby\nputs 1\nputs 2\n"  ->  <pre data-sourcepos="3:1-5:6">   (fence opened line 3)
```

The end line is **the last line that has content**. Degenerate opens report a position too:
`` ```ruby\n `` → `1:1-1:7`; a bare `` ``` `` with no newline → `1:1-1:3`; a half-typed
`` ```ru `` → `1:1-1:5`, and `fence_info` already reads `"ru"`. The node is typed
`:code_block` with `fenced? == true` from the first partial fence line onward.

**Caveat the design must absorb:** a *closed* fence reports the **closing fence line** as its
end (`1:1-3:3` for `` ```ruby\nputs 1\n```\n ``), an *open* one reports its last content line
(`1:1-2:6`). Both are non-nil, so **sourcepos alone cannot tell an open block from a closed
one.** The splitter must look at the source text on the reported end line (or track the buffer
tail) to decide. This does not invalidate Route A — it just means "is this block still open?"
is a separate question from "where does it end?".

### Q2 — Are ranges on **every** top-level block type? **No. HTML blocks have none.**

This **contradicts the Route A decision as written.** A full-spectrum document renders with
`data-sourcepos` on `h1 p blockquote ul ol table pre hr section(footnotes)` and on task lists,
tables, indented code and thematic breaks — but the raw `<div>` from an HTML block comes out
with **no attribute at all**:

```
div          sourcepos=nil
```

The reason is structural, not a bug: with `unsafe: true` comrak copies the HTML block through
verbatim, so there is no comrak-generated tag to hang an attribute on. With `unsafe: false`
(the default) the block is replaced by `<!-- raw HTML omitted -->` — also unattributed.

The node API *does* have the position: `:html_block` reports
`{start_line: 3, start_column: 1, end_line: 5, end_column: 6}`.

**What this means for Phase 3.** Route A is still the primary path, but it is **not sufficient
on its own**. The block splitter must handle a top-level element with no `data-sourcepos`.
Two workable shapes:

1. **Interpolate.** Unattributed elements sit between two attributed ones; the gap in line
   coverage is exactly the unattributed block's range. Cheap, needs no second parse, and
   degrades gracefully if a future comrak drops the attribute somewhere else.
2. **Cross-reference Route B.** Parse once more with `Commonmarker.parse` and zip the
   top-level node list against the top-level element list.

Prefer (1). Whichever is chosen, **the splitter needs a test with an HTML block in it**, and
the "walk top-level elements, read `data-sourcepos`" sentence in Decision 1 is now incomplete —
read it as "read `data-sourcepos`, and have an answer for when it is absent".

A second, smaller gap in the same family: **link reference definitions render to nothing.**
`[r]: https://example.com` on its own line produces no element, so those lines are claimed by
no range at all. A splitter that assumes total line coverage will mis-slice.

### Q3 — Does `sourcepos_chars: true` behave with CJK and emoji? **Yes, exactly as hoped.**

For the line `日本語 **強調** 🎉 tail` (17 characters, 30 bytes):

| | block range | `<strong>` range |
|---|---|---|
| `sourcepos_chars: false` (default) | `1:1-1:30` | `1:11-1:20` |
| `sourcepos_chars: true` | `1:1-1:17` | `1:5-1:10` |

Columns become **Ruby `String#length` offsets** — codepoints, which is precisely what
`String#[]` indexes by. Slicing the strong span by character columns yields `**強調**`;
slicing by the byte columns yields `" 🎉 tail"` — **silently wrong, no exception**. That is the
bug class Decision 2 was written to kill, and it is real.

It counts **codepoints, not grapheme clusters**, and that is the correct choice because Ruby
slices by codepoints too: `👨‍👩‍👧‍👦 family` is 14 codepoints / 8 clusters and reports column 14;
`🇲🇽 flag` is 7 / 6 and reports 7; `e` + U+0301 + `" combining"` is 12 / 11 and reports 12. In
every case `line[0, end_column]` round-trips the line.

Line numbers are unaffected by the flag. Inline nodes shift along with block nodes.

**Decision 2 stands, strengthened.** Turn `sourcepos_chars: true` on and never read a column
with `byteslice`.

## Other runtime surprises the source inspection missed

- **`Commonmarker.to_html` syntax-highlights by default.** `Config::PLUGINS` defaults to
  `{ syntax_highlighter: { theme: "base16-ocean.dark", path: "" } }`, so code blocks come back
  as inline-styled `<span>`s inside a `<pre style="background-color:#2b303b;">`. Phase 2 owns
  highlighting (Rouge, plus client-deferred renderers), so the engine must pass
  `plugins: { syntax_highlighter: nil }` or it will ship two highlighters fighting each other —
  and hand the sanitizer a pile of inline styles.
- **`github_pre_lang` defaults to `true`**: the language lands as `lang="ruby"` on `<pre>`, not
  as `class="language-ruby"` on `<code>`. Anything keying off the conventional class name will
  find nothing.
- **Attribute order on `<pre>` is not stable** between the highlighted and unhighlighted paths.
  Parse the HTML; never string-match a whole opening tag.
- **Positions do not reliably nest.** A bullet list followed directly by an ordered list gives
  `<ul data-sourcepos="1:1-2:3">` containing `<li data-sourcepos="2:1-3:0">` — the child ends a
  line past its parent, on the blank separator. Clamp child ranges to the parent's.
- **End column `0` is a real value**, meaning "end of the previous line" (indented code blocks
  produce `3:5-4:0`). It is not an index; treating it as one underflows.
- **The same block reports different ranges depending on what follows it.** An indented code
  block is `3:5-3:17` at end of document and `3:5-4:0` with a trailing blank line. Any splitter
  invariant asserted on a document tail must be re-checked on the next chunk — which is exactly
  the streaming case, and exactly why correctness lives in the repair path.
- `Commonmarker.to_html` takes only `text`, `options:` and `plugins:`. Extensions go **inside**
  `options` as `options: { extension: {...} }`; a top-level `extension:` keyword raises
  `ArgumentError`.
