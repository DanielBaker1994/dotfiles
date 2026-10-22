#!/usr/bin/env bash

# Startup profiler hook: `shellprof` (bash/shellprof.sh) starts a login shell
# with BASHPROF=FILE; every line from here to the bottom of this file
# (.bashrc and ~/external/* included) is traced into FILE with a timestamp.
if [[ -n ${BASHPROF:-} && -n ${EPOCHREALTIME:-} ]]; then
    _bashprof_ps4="$PS4"
    exec {BASH_XTRACEFD}>>"$BASHPROF"
    PS4='+${EPOCHREALTIME}	${BASH_SOURCE[0]:-?}:${LINENO}	${FUNCNAME[0]:-}	'
    set -x
fi

# Machine-local overrides kept outside this repo. Sourced first so it can seed
# PATH and exports before the rest of this file runs. It is expected to be
# machine-specific and may not exist at all, so guard the source.
if [ -f "$HOME/external/.bash_profile" ]; then
    source "$HOME/external/.bash_profile"
fi

# brew paths are added by `brew shellenv` below; keep texbin + mason here.
export PATH=$HOME/.local/bin:/Library/TeX/texbin:$HOME/.local/share/nvim/mason/bin:$PATH # ~/.local/bin holds herdr
export XDG_CONFIG_HOME="$HOME/.config"

# .bashrc (sourced below) and starship call brew-installed tools (zoxide, fzf,
# starship) before `brew shellenv` runs at the bottom, and a fresh login shell
# has no /opt/homebrew/bin yet -> "command not found" until herdr inherits it.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

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

if [[ -f $HOME/.bashrc ]]; then
    source "$HOME/.bashrc"
fi

[[ $- == *i* ]] && eval "$(starship init bash)"

# Must go last or usr bin will come before home brew and then path which fild old bash.
eval "$(/opt/homebrew/bin/brew shellenv)"

# end of the BASHPROF trace (hook at the top); unsetting the fd closes it
if [[ -n ${_bashprof_ps4+x} ]]; then
    set +x
    unset BASH_XTRACEFD BASHPROF
    PS4="$_bashprof_ps4"
    unset _bashprof_ps4
fi

if [[ $- == *i* ]]; then
    if [[ -s $HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh ]]; then
        . "$HOMEBREW_PREFIX/etc/profile.d/bash_completion.sh"
    fi
    complete -F _starship -o nosort -o bashdefault -o default starship
fi
