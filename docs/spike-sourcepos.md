# Spike: CommonMarker source positions

**Date:** 2026-09-06 · **Status:** resolved, no redesign required
**Method:** source inspection of `gjtorikian/commonmarker` at `v2.10.0` (no Ruby toolchain in the spike environment; verify empirically in Phase 1).

## Question

Phase 3's block splitter depends on mapping parsed blocks back to line ranges of the raw buffer. CommonMarker 2.x moved from cmark-gfm to comrak, and the concern was that the node API had been dropped, which would have forced a structural pre-parse scan instead.

## Finding

Both routes exist and are healthy in 2.10.0.

### Route A — sourcepos on rendered HTML (preferred)

```ruby
Commonmarker.to_html(md, options: { render: { sourcepos: true } })
# => <p data-sourcepos="2:1-2:9">paragraph</p>
```

Confirmed in `test/sourcepos_test.rb`. Every block-level element carries `data-sourcepos="startLine:startCol-endLine:endCol"`.

This is better than the design assumed. The Nokogiri post-pass receives line ranges directly on the elements it is already walking — no separate AST traversal, and no correlation step between tree and output.

### Route B — node API (available, use where A is awkward)

`Commonmarker.parse(text)` returns a node tree. Bound node methods include:

`get_sourcepos` `get_first_child` `get_last_child` `get_next_sibling` `get_previous_sibling` `get_parent` `type_to_symbol` `get_fenced` `get_fence_info` `get_literal` `get_string_content` `to_html` `to_commonmark`

`get_sourcepos` returns `{ start_line:, start_column:, end_line:, end_column: }`.

`get_fenced` and `get_fence_info` give open-fence detection and the language string directly, which Phase 2 needs for the renderer-strategy registry and Phase 3 needs for deferred highlighting.

## Decisions this settles

1. **Block splitter uses Route A.** Walk top-level elements of the rendered HTML, read `data-sourcepos`, slice the raw buffer by line range. Strip the attribute in the same pass unless debugging.
2. **Enable `parse: { sourcepos_chars: true }`.** comrak exposes this; it makes column numbers count characters rather than bytes. Ruby string slicing is character-based, so enabling it removes a whole class of off-by-N bug on multibyte content — which agent output contains constantly.
3. **Do not render blocks in isolation via `Node#to_html`.** Tempting for sealing, but a node rendered alone loses link reference definitions declared elsewhere in the document. Render the whole buffer and slice the output.

## Verify empirically in Phase 1

Source inspection cannot confirm runtime behaviour. Three checks, cheap to write:

- Does an **unterminated** fenced code block still report a `sourcepos` end line? The splitter's open-block handling depends on it.
- Are `data-sourcepos` ranges present on **every** top-level block type, including tables, block quotes and HTML blocks?
- Does `sourcepos_chars: true` behave as expected with CJK and emoji in the same line as markup?
