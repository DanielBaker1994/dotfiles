<article class="enable_pretty_title">
# Daniel Workspace Documents
Setting up workspace and suggested commands.

<article class="article enable_pretty_headers">
<article class="article enable_pretty_lines">




```{.bash}
# For neovim easier now to ~/cd to workspace
cd ~
ln -s ~/src/cpp_workspace ~/cpp
ln -s ~/src/java_workspace ~/java
ln -s ~/src/root_workspace ~/root
```



```{.vim}
# Telescope filter files. Rip grep create inclusive OR.
# Note two spaces folowing target string.
teststring  **.cpp **.h

# Terminal open. Toggles terminal
<leader>to

#  Search my neovim and quick files
<leader>sn


#  Markdown Open. Must be on a .md file.
<leader>mdo
```






> [!INFO]
> Code blocks like \"vim\" do not exist in pandoc. They can be added by passing a syntax definition.
>
> A valid XML style file can be copied and renamed to the new type:
>
> \--syntax-definition=\"$HOME/.config/markdown_generator/vim.xml\"
>
> Github below:
>
> https://github.com/KDE/syntax-highlighting/blob/master/data/syntax/bash.xml
>
> A language block needs to match the filename. It does not seem possible to map multiple languages to the same file, so you'll likely have to copy the file and update the respective name and language for more.
>
> \<language name=\"vim\" \>



> [!INFO]
> iTerm2 window can be hidden like Kitty.

![](/Users/danielbaker/.dotfiles/doc/hiding_menu_bar.png)
