# maquina_remend — pattern specification

The upstream test suite is not vendored here. Generate fixtures from this specification rather than from memory: one fixture file per numbered case, named `test/fixtures/remend/<nn>_<slug>.txt` with three sections (`--- input`, `--- expected`, `--- note`).

Every handler must be individually disableable, and all default to on except where marked.

## Completion handlers

| # | Pattern | Input (streaming tail) | Expected output |
|---|---|---|---|
| 01 | bold | `**unclosed bold` | `**unclosed bold**` |
| 02 | italic asterisk | `*unclosed` | `*unclosed*` |
| 03 | italic underscore | `_unclosed` | `_unclosed_` |
| 04 | bold italic | `***both` | `***both***` |
| 05 | inline code | `` `code `` | `` `code` `` |
| 06 | strikethrough | `~~struck` | `~~struck~~` |
| 07 | link, text open | `[label` | `[label]()` or plain text — see `link_mode` |
| 08 | link, url open | `[label](http` | placeholder URL, or `label` as text |
| 09 | image | `![alt` | `![alt]()` |
| 10 | block math | `$$x = 1` | `$$x = 1$$` |
| 11 | inline math *(off by default)* | `$x = 1` | `$x = 1$` |
| 12 | setext heading | `Title\n=` | heading, not literal `=` |
| 13 | truncated html tag | `text <div cla` | `text` — tag stripped |

## Guard handlers (prevent false positives)

| # | Pattern | Input | Expected | Why |
|---|---|---|---|---|
| 20 | fenced code | ` ```\n**not bold ` | unchanged | never complete inside a fence |
| 21 | inline code | `` `a * b` `` | unchanged | asterisk is literal |
| 22 | math context | `$$a_1 + b_2$$` | unchanged | underscores are subscripts |
| 23 | LaTeX parens | `\(a_1\)` | unchanged | math context is not only `$` |
| 24 | identifier | `some_var_name` | unchanged | underscores inside words |
| 25 | single tilde | `20~25°C` | escaped, not struck | numeric range |
| 26 | currency | `costs $5 and $10` | unchanged | why case 11 is off by default |
| 27 | comparison in list | `- a > b` | `>` escaped | otherwise parsed as blockquote |
| 28 | complete input | any well-formed doc | byte-identical | the no-op property |

## Properties (assert over the whole corpus)

1. **Idempotence** — `call(call(x)) == call(x)`
2. **No-op on well-formed input** — case 28 generalized to every complete fixture
3. **Prefix safety** — for a corpus of complete documents, every truncation point produces output that parses without raising
4. **Performance** — under 1ms for an 8KB buffer

## Corpus sources

Build the prefix-safety corpus from at least 20 real agent transcripts containing: nested lists with code, tables mid-stream, mermaid and math fences, mixed CJK and Latin, and messages that were cancelled mid-token.
