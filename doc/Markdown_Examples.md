<article class="enable_pretty_title">
# Markdown Examples
Paired raw → rendered examples

<article class="article enable_pretty_headers">
<article class="article enable_pretty_lines">


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


## Example: Headers (H1 / H2 / H3)

# Example Header One

## Example Header Two

### Example Header Three
