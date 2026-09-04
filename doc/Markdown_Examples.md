# Markdown Examples
Paired raw → rendered examples

----

# Markdown: raw-before-rendered examples



## Admonitions


> [!WARNING]
> WARNING on a very long line still going 1233456788
>
> Note the line break before is required to avoid single line



> [!ERROR]
> ERROR I wanted two lines. 
> But this renders on one line.
>
> But this renders on a new line.




> [!TIP]
> TIP on a very long line still going 1233456788 abcdedfghighklmonopyerstuvwxyz


> [!INFO]
> INFO on a very long line still going 1233456788 abcdedfghighklmonopyerstuvwxyz


> [!FILE]
> ~/.config/markdown_generator/friendly_document_styling.css
>
> /tmp/directory/test.txt



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


```{.file}
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

> A plain blockquote without a `[!TAG]` first line keeps standard markdown
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
pandoc -s -f markdown+raw_html -t html5 \
  --include-in-header="$DOTDIR/markdown_generator/friendly_document_styling.css" \
  --include-in-header="$DOTDIR/markdown_generator/copy_button.css" \
  --include-after-body="$DOTDIR/markdown_generator/copy_button.js" \
  -o out.html in.md
```

> [!INFO]
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
