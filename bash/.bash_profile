#!/usr/bin/env bash

# brew paths are added by `brew shellenv` below; keep texbin + mason here.
export PATH=/Library/TeX/texbin:$HOME/.local/share/nvim/mason/bin:$PATH

export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig/:$PKG_CONFIG_PATH
export FZF_DEFAULT_OPTS="--height=40% --layout=reverse --info=inline --border --margin=1 --padding=1 --bind 'ctrl-n:down,ctrl-p:up'"
# Ctrl-R widget-only bindings (fzf's bash integration reads FZF_CTRL_R_OPTS):
# Ctrl-Y copies the highlighted history entry to the clipboard and closes.
# The history line is "number<TAB>command", so the leading number is stripped.
# NOTE: use execute (sync), NOT execute-silent — silent is async and +abort
# kills the copy before pbcopy finishes. `command pbcopy` sidesteps any
# pbcopy alias. Add more bindings by extending the --bind list, e.g.
#   --bind "ctrl-y:...,ctrl-l:execute(...)"
export FZF_CTRL_R_OPTS='--bind "ctrl-y:execute(printf %s {} | sed -E '\''s/^[0-9]+[[:space:]]+//'\'' | command pbcopy)+abort"'
# What fzf lists: ripgrep so .gitignore / .ignore / .rgignore are respected.
# Runs in the current directory on every invocation, so it's dynamic.
export FZF_DEFAULT_COMMAND='rg --files --hidden --follow --glob "!.git"'

export DOTDIR="$HOME/.dotfiles"

export ASSET_PICTURES_DIRECTORY_GLOBAL="$HOME/Documents/AssetsScreenshots"
export NERDFONT_PATH_GLOBAL="$HOME/Library/Fonts/HackNerdFont-Regular.ttf"
export DEV_NOTES="$HOME/Desktop/DevNotes"
export DEV_WORKSPACE="$DEV_NOTES/Workspace"

#much nicer man pages from neovim
export MANPAGER="nvim +Man!"

# external.sh is sourced by ~/.bashrc (below) — once, not twice.
if [[ -f ~/.dotfiles/bash/tmux_connect.sh ]]; then
    source "$HOME/.dotfiles/bash/tmux_connect.sh"
fi

if [[ -f $HOME/.bashrc ]]; then
    source "$HOME/.bashrc"
fi

eval "$(starship init bash)"

# Must go last or usr bin will come before home brew and then path which fild old bash.
eval "$(/opt/homebrew/bin/brew shellenv)"

if [[ -s $HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh ]]; then
    . "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
fi
complete -F _starship -o nosort -o bashdefault -o default starship
