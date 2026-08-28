#!/usr/bin/env bash

export PATH=/Library/TeX/texbin:$HOME/.local/share/nvim/mason/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH

export PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig/:$PKG_CONFIG_PATH
export FZF_DEFAULT_OPTS="--height=40% --layout=reverse --info=inline --border --margin=1 --padding=1 --bind 'ctrl-n:down,ctrl-p:up'"

export DOTDIR="$HOME/.dotfiles"

export ASSET_PICTURES_DIRECTORY_GLOBAL="$HOME/Documents/AssetsScreenshots"
export NERDFONT_PATH_GLOBAL="$HOME/Library/Fonts/HackNerdFont-Regular.ttf"
export DEV_NOTES="$HOME/Desktop/DevNotes"
export DEV_WORKSPACE="$DEV_NOTES/Workspace"

#much nicer man pages from neovim
export MANPAGER="nvim +Man!"

if [ -f ~/.dotfiles/bash/tmux_connect.sh ]; then
    source "$HOME/.dotfiles/bash/tmux_connect.sh"
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

#Dont delete me, it is used by neovim
#specifying dot files is ugly trick to show some hidden files in rip grep
#without having to enable all of them
function EXTERNAL_PATHS_GLOBAL() {
    quickpaths=(
        "$DOTDIR"
        "$DOTDIR/bash/.bashrc"
        "$DOTDIR/bash/.inputrc"
        "$DOTDIR/bash/.bash_profile"
        "$DOTDIR/clang/.clang-format"
        "$DOTDIR/tmux/.tmux.conf"
        "$DOTDIR/git/.gitconfig"
    )
    echo "${quickpaths[@]}"

}

# root = base dir where all git worktrees live; prefix = name prefix of each
# worktree dir (e.g. ~/jira/JT-123); target lines are name<TAB>subpath relative
# to the matched worktree.
function NVIM_CD_TARGETS() {
    printf 'root\t%s\n' "$HOME/jira"
    printf 'prefix\t%s\n' 'JT'
    printf 'top\t.\n'
    printf 'cpp\tcpp\n'
}
