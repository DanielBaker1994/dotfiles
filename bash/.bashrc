#!/usr/bin/env bash

# Machine-local overrides kept outside this repo. Sourced first so it can seed
# PATH and exports before the rest of this file runs. It is expected to be
# machine-specific and may not exist at all, so guard the source.
if [ -f "$HOME/external/.bashrc" ]; then
    source "$HOME/external/.bashrc"
fi

# Guard against a stale `f` alias from a previous .bashrc: bash expands aliases
# at parse time, so an existing alias would corrupt this function definition.

function aerospacelist() {
    aerospace list-windows --all --format "%{window-id} | %{app-name} | %{workspace} | %{window-parent-container-layout} | %{window-title}"
    aerospace layout v_accordion
    aerospace layout h_accordion
    aerospace layout v_tiles
    aerospace layout h_tiles
}

# Close herdr workspaces ("spaces") by label.
#   close_spaces kitchen-sink quickterm      # explicit names
#   close_spaces                             # uses $CLOSE_SPACES
# CLOSE_SPACES = space-separated space names to close. NOTE: export it in
# ~/external/.bashrc (sourced above) so work and home can differ without
# conflicting; this is only the fallback.
#   export CLOSE_SPACES="kitchen-sink quickterm keepalive"
# Names that match no workspace are reported and skipped. The focused
# workspace is skipped too (closing it would kill the shell running this).
export CLOSE_SPACES="${CLOSE_SPACES:-kitchen-sink quickterm}"
close_spaces() {
    local -a names=("$@")
    # shellcheck disable=SC2206  # intentional word splitting of the env var
    ((${#names[@]})) || names=($CLOSE_SPACES)
    local json name id focused
    json=$(herdr workspace list) || return 1
    for name in "${names[@]}"; do
        id=$(jq -r --arg n "$name" '.result.workspaces[] | select(.label==$n) | .workspace_id' <<<"$json" | head -n1)
        if [ -z "$id" ]; then
            echo "close_spaces: no workspace named '$name'" >&2
            continue
        fi
        focused=$(jq -r --arg n "$name" '.result.workspaces[] | select(.label==$n) | .focused' <<<"$json" | head -n1)
        if [ "$focused" = true ]; then
            echo "close_spaces: skipping '$name' (focused)" >&2
            continue
        fi
        herdr workspace close "$id" >/dev/null && echo "closed $name"
    done
}

unalias f 2>/dev/null
f() {
    # Cancel (ESC) -> no selection -> nothing copied.
    # Ctrl+Y copies the highlighted entry's ABSOLUTE path ($PWD + the path,
    # since rg --files outputs paths relative to the current dir) to the
    # clipboard and exits. {} = the selected line; fzf auto-quotes it, so
    # keep it unquoted in the printf (wrapping in "..." would break paths
    # with spaces).
    # Sync execute (not execute-silent) so pbcopy finishes before abort.
    # Enter opens the selected file (absolute path) in nvim.
    local sel
    sel=$(fzf --bind 'ctrl-y:execute(printf %s $PWD/{} | command pbcopy)+abort') || return
    nvim "$PWD/$sel"
}
# Home-server helpers (proxmoxmediaconnect, mealplannerconnect, filesmount, ...)
# live in the private ~/home_server repo, sourced from ~/external/.bashrc above.

alias bashr='source ~/.bash_profile'
alias bbopen='nvim ~/.bash_profile'
alias bopen='nvim ~/.bashrc'
alias topen='nvim ~/.tmux.conf'
alias tsource='tmux source ~/.tmux.conf'
alias vi='nvim'
alias vim='nvim'
alias vopen='nvim ~/.config/nvim/init.lua'
alias bat='bat --no-pager'
alias clear="TERM=xterm /usr/bin/clear" #terminals database is inaccessible
alias cls="clear && printf '\e[3J'"
alias pbcopy="perl -pe 'chomp if eof' | pbcopy"
alias cddot="cd ~/.dotfiles"
# profiling: shell startup (shellprof help) and herdr plugin handlers (herdrprof help)
alias shellprof='bash ~/.dotfiles/bash/shellprof.sh'
alias herdrprof='bash ~/.dotfiles/herdr/herdr-prof.sh'
[ -f "$HOME/.dotfiles/bash/aliases-backup.sh" ] && source "$HOME/.dotfiles/bash/aliases-backup.sh"
alias ..="cd .."

if [ -f "$HOME/.dotfiles/bash/workflow.sh" ]; then
    source "$HOME/.dotfiles/bash/workflow.sh"
fi

FILE_LINES=/tmp/files_lines.txt
alias ga='git add -u'
alias gs='git status'
parse_git_branch() {
    local b
    b=$(git symbolic-ref --short HEAD 2>/dev/null) && printf ' (%s)' "$b" || printf ' (detached)'
}
export PS1='\u \w $(parse_git_branch) >'

function setdebug() {
    export PS4='+${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}(): '
    set -x
}
function unsetdebug() {
    export PS4='+ '
    set +x
}

function killshellcheck() {
    ps -ef | grep -i shellcheck | awk -F ' ' '{print $2}' | xargs kill -9
}

filepathsquick() {
    mapfile files < <(EXTERNAL_PATHS_GLOBAL)
    file_select=$(printf "%s\n" "${files[@]}" | fzf --reverse --header "Select a file alias or action")
    [ -z "$file_select" ] && return 0
    if [[ -f "$file_select" ]]; then
        tmux new-window -n "${file_select##*/}" "${file_select%/*}; nvim $file_select"
    fi
}

function show_file_lines {
    true >$FILE_LINES
    while read -r data; do
        printf "%s\n" "$data" >>$FILE_LINES
    done
    mapfile lines < <(cat $FILE_LINES)
    i=1
    for line in "${lines[@]}"; do
        printf "%s" "$((i)): $line"
        ((i += 1))
    done
}

function of() {
    [[ -z "$1" ]] && echo "Must provide a number" && return
    mapfile lines < <(cat $FILE_LINES)
    vim "$(printf %s "${lines[(($1 - 1))]}")"
}

function cf() {
    [[ -z "$1" ]] && echo "Must provide a number" && return
    mapfile lines < <(cat $FILE_LINES)
    printf %s "${lines[(($1 - 1))]}" | tr -d '\n' | pbcopy && echo "Line copied" || echo "Did not copy"
}

function e() {
    ret=$*
    ret=${ret^^}
    ret=${ret// OR /|}
    ret=${ret// /.*}
    find "$PWD" -type f \
        ! -name '*.idx' \
        ! -name '*.o' \
        ! -name '*.s' \
        -print |
        grep -Ei "$ret" | show_file_lines
}

function Oil() {
    nvim -c ":Oil"
}
function oil() { Oil; }

# Fuzzy-search and focus any AeroSpace window (id | app | title).
# Enter focuses, ESC cancels. Works from any terminal.
win() {
    aerospace list-windows --all |
        fzf --prompt='window> ' \
            --header='enter: focus | esc: cancel' \
            --bind='enter:execute($SHELL -c "aerospace focus --window-id {1}")+abort' \
            --bind='esc:abort'
}

# External commands & config consumed by nvim (EXTERNAL_BUILD_AND_OPEN_PDF,
# EXTERNAL_PATHS_GLOBAL, NVIM_CD_TARGETS, JIRA_URL). Kept together in one file.
if [ -f ~/.dotfiles/bash/external.sh ]; then
    source "$HOME/.dotfiles/bash/external.sh"
fi

. "$HOME/.cargo/env"

# source_init NAME ARGS...: source the output of `NAME ARGS...`, cached in
# ~/.cache/bash-init/NAME.bash. Init scripts only change when the tool is
# upgraded, and starting the tool on every shell was the slowest part of
# startup on the work Mac (shellprof). Builtins only on a cache hit: the cache
# is rebuilt when it is missing, or older than the binary or the directory
# holding it (`brew upgrade` relinks into a new Cellar version, which touches
# that directory). Force a rebuild: rm -r ~/.cache/bash-init
source_init() {
    local name="$1" bin cache="$HOME/.cache/bash-init/$1.bash"
    hash "$name" 2>/dev/null || return 0
    bin="${BASH_CMDS[$name]}"
    if [[ ! -s $cache || $bin -nt $cache || ${bin%/*} -nt $cache ]]; then
        mkdir -p "${cache%/*}"
        "$@" >"$cache.$$" && mv -f "$cache.$$" "$cache" || { rm -f "$cache.$$"; return 0; }
    fi
    source "$cache"
}

# Skip these for non-interactive shells such as nvim's `bash -lc` prefetches
# (see nvim/lua/bash_external/init.lua).
if [[ $- == *i* ]]; then
    source_init zoxide init bash
    # fzf keybindings for bash: Ctrl-R (history search), Ctrl-T (files), Alt-C (cd)
    source_init fzf --bash
fi

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH" # herdr, claude, etc.

if [ -f "$HOME/.config/kitchen-sink/bin/utils.sh" ]; then
    source "$HOME/.config/kitchen-sink/bin/utils.sh"
fi
