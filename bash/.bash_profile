#!/usr/bin/env bash

export PATH=/Library/TeX/texbin:$HOME/.local/share/nvim/mason/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH

export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig/:$PKG_CONFIG_PATH
export FZF_DEFAULT_OPTS="--height=40% --layout=reverse --info=inline --border --margin=1 --padding=1"

export DOTDIR="$HOME/.dotfiles"

export ASSET_PICTURES_DIRECTORY_GLOBAL="$HOME/Documents/AssetsScreenshots"
export NERDFONT_PATH_GLOBAL="$HOME/Library/Fonts/HackNerdFont-Regular.ttf"
export DEV_NOTES="$HOME/Desktop/DevNotes"
export DEV_WORKSPACE="$DEV_NOTES/Workspace"

#much nicer man pages from neovim
export MANPAGER="nvim +Man!"

if [ -f ~/tmux_connect.sh ]; then
    source "$HOME/tmux_connect.sh"
fi

if [ -f ~/.bashrc ]; then
    source "$HOME"/.bashrc
fi

eval "$(starship init bash)"

# Must go last or usr bin will come before home brew and then path which fild old bash.
eval $(/opt/homebrew/bin/brew shellenv)

if [[ -s $HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh ]]; then
    . "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
fi
if [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 || "${BASH_VERSINFO[0]}" -gt 4 ]]; then
    complete -F _starship -o nosort -o bashdefault -o default starship
else
    complete -F _starship -o bashdefault -o default starship
fi
