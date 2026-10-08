<div class="doc tokyo-night"></div>

# Markdown Examples
Paired raw → rendered examples

----

# Markdown: raw-before-rendered examples



## Alerts

GitHub alerts: exactly five types (NOTE, TIP, IMPORTANT, WARNING, CAUTION),
rendered by GitHub, nvim (render-markdown) and pandoc `-f gfm` without a filter.
Any other `[!TAG]` stays a plain blockquote.


> [!NOTE]
> NOTE on a very long line still going 1233456788 abcdedfghighklmonopyerstuvwxyz
>
> `~/.config/markdown_generator/friendly_document_styling.css`


> [!TIP]
> TIP on a very long line still going 1233456788 abcdedfghighklmonopyerstuvwxyz


> [!IMPORTANT]
> IMPORTANT: key information needed to succeed.


> [!WARNING]
> WARNING on a very long line still going 1233456788
>
> A blank `>` line starts a new paragraph; a plain newline joins lines.


> [!CAUTION]
> CAUTION I wanted two lines.
> But this renders on one line.
>
> But this renders on a new line.



----


## Bash


```bash
mapfile -t brew_list < <(brew list --cask && brew list --installed-on-request)
for b in "${brew_list[@]}"; do
    echo "$b" >>.brew_install_list.txt
done
```

----

## Python


```python
if 5 > 2:
    print("Five is greater than two!")
```

----

## Lua


```lua
local dirs = { vim.fn.stdpath('config') }
for _, p in ipairs(parts) do
    if p:match("%S") then table.insert(dirs, p) end
end
return dirs
```

----

## cpp 


```cpp
#include <iostream>
int main(){ std::cout << "hello"; }
```

----

## Log block

```log
[WARN] example warning
[ERROR] example error
[WARN] example warning
[ERROR] example error
[WARN] example warning
[ERROR] example error
[WARN] example warning
[ERROR] example error
```

----

## File block


```file
/path/to/some/file.txt
~/.config/markdown_generator/friendly_document_styling.css
```

----

## Image




![](/Users/danielbaker/.dotfiles/doc/RenderedPhotoExample.png)




----

## Table


| Column1 | Column2 | Column3 |
| ------- | ------- | ------- |
| Item1.1 | Item2.1 | Item3.1 |
| Item1.2 | Item2.2 | Item3.2 |

----

## Nested list

- header_level_one
    - header_level_two
        - header_level_three




### Numbered list

1. first
2. second
3. third



----

## Inline code, links & plain quotes

Here is `inline code` rendered as a chip, next to [a link to pandoc.org](https://pandoc.org)
and ordinary text.

> A plain blockquote without a `[!NOTE]`-style first line keeps standard markdown
> styling: muted text behind a soft blue left bar.

----


## Example: Headers (H1 / H2 / H3)

# Example Header One

## Example Header Two

### Example Header Three

----

## Copy buttons on code blocks (what we learned)

Every code block in generated HTML gets a one-click copy button (blue
overlapping-squares icon) on its left side, injected at render time.

```bash
# markdown_generator/copy_button.js  - injection + click handler
# markdown_generator/copy_button.css - side-strip button styling
```

Wired into the pandoc pipeline in `EXTERNAL_BUILD_AND_OPEN_PDF`
(`~/.dotfiles/bash/external.sh`):

```bash
pandoc -s -f gfm -t html5 \
  --include-in-header="$DOTDIR/markdown_generator/friendly_document_styling.css" \
  --include-in-header="$DOTDIR/markdown_generator/copy_button.css" \
  --include-after-body="$DOTDIR/markdown_generator/copy_button.js" \
  -o out.html in.md
```

> [!NOTE]
> `--include-in-header` and `--include-after-body` both insert files
> VERBATIM - nothing is auto-wrapped for you. Following the repo convention
> (`friendly_document_styling.css` does the same), the CSS include carries its
> own `<style>...</style>` wrapper and the JS include its own
> `<script>...</script>` wrapper. A bare file lands as visible text on the page
> (or raw JS that never runs).

> [!WARNING]
> Don't position the button absolutely over the `<pre>`:
> - the code blocks already have `::before` language icons (bash/cpp/lua logos)
>   from `friendly_document_styling.css` that the overlay collides with
> - an overlay also blocks selecting/copying the code text by hand
>
> The working design: JS wraps each `<pre>` in `<div class="codeblock">`
> (`display: flex`) and appends the button as a SIBLING before the `<pre>` -
> button on the left, code on the right, nothing overlapping.

> [!TIP]
> - The clipboard API needs a real user gesture: programmatic `.click()`
>   (e.g. from devtools) silently hangs; a real mouse click works. A
>   `document.execCommand("copy")` fallback covers browsers without the API.
> - Copied text = `code.innerText` of the block.
> - Firefox gotcha: `open file.html` reuses the existing tab WITHOUT
>   reloading - after regenerating HTML you must Cmd+R to see changes.
> - weasyprint runs no JS, so the PDF output is unaffected by all of this.

## Document templates (one marker restyles everything)

Put one line anywhere in the markdown (nvim snippets `markdown_doc_tokyo_night`,
`_paper`, … one per template; defined in kitchen-sink
`vim/snippets/markdown.json`):

```html
<div class="doc tokyo-night" data-foot="Confidential"></div>
```

- `# Title` = page-1 title and the running header on pages 2+; the paragraph
  right under it = subtitle (header, right). `data-foot` = footer text; the
  footer's right side is "Page n of N".
- No marker = the plain style, unchanged. Templates live ONLY in
  `markdown_generator/friendly_document_styling.css` (palette vars `--p-*`,
  `--t-*`, `:root:has(.name)`); the kitchen-sink app loads that same file
  (`[notes] pdf-css`), so reading view, Export PDF and
  `EXTERNAL_BUILD_AND_OPEN_PDF` render identically. New template = copy a
  `:root:has(.name) { … }` palette block.

Templates: `tokyo-night` `paper` `executive` `terminal`, plus researched
palettes (official hex values) `catppuccin-mocha` `catppuccin-latte` `dracula`
`nord` `gruvbox-dark` `gruvbox-light` `solarized-dark` `solarized-light`
`rose-pine` `rose-pine-dawn`. In the app, the ◐ chip on the Prose | nvim switch
lists them (read from the stylesheet's palette blocks).

## Developer callouts, badges and the insert picker

Callouts (`<div class="callout KIND">`, a blank line, markdown, a blank line,
`</div>`): `decision` `risk` `breaking` `deprecated` `action` `example`
`question` `rollback` `perf`. The label is drawn by the CSS — don't repeat it
in the text. Badges: `<span class="badge ok">Shipped</span>` (`ok warn bad
info muted accent`). ` ```diff ` colors removed / added / hunk lines.
Page break: `<div class="pagebreak"></div>`. All CSS is in
`friendly_document_styling.css` (works with or without a style marker).

nvim insert picker (kitchen-sink `vim/snippets.lua`): `<leader>i` (normal mode)
or `:Insert` — fuzzy search over every snippet, grouped by
`category`, with a preview. Type `3x4` for a table (3 body rows x 4 columns),
`clipboard` to turn copied CSV / TSV into a table. Skeleton snippets:
`markdown_doc_adr`, `_postmortem`, `_runbook`, `_pr`, `_status`, `_professional`,
plus `markdown_api_endpoint`, `markdown_changelog_entry`.

## Diagrams (Graphviz + D2)

` ```dot ` / ` ```graphviz ` (Graphviz) and ` ```d2 ` fences become inline diagrams
in the prose view, Export PDF and `EXTERNAL_BUILD_AND_OPEN_PDF`, coloured from the
document's style marker (no marker = neutral grays). Filter:
`markdown_generator/diagrams.lua` (kitchen-sink `[notes] pdf-filter`; default =
beside `pdf-css`; `none` = off). Needs `brew install graphviz d2`. Don't write
colors in the diagram — write nodes and edges only. A syntax error renders as a red
box with the tool's message and your own line number. Snippets (category Diagrams):
`markdown_dot_flowchart`, `_dot_architecture`, `_d2_flowchart`, `_d2_architecture`,
`_d2_sequence`, `_d2_erd`. Cached by content in `~/.cache/kitchen-sink/diagrams`.

## One stylesheet (how it is managed)

`markdown_generator/friendly_document_styling.css` is the only place the rules live.
Every color is a `--p-*` variable: the `:root` block at its top = the plain light
style; the kitchen-sink app appends its theme's `:root { --p-* }` after it; a
`<div class="doc NAME">` marker overrides both with `:root:has(.NAME)`. kitchen-sink's
`prose_theme.css` is now empty of rules. `copy_button.css` is shared the same way.
New template = one palette block in that file.
