#!/usr/bin/env bash
# Guard against a stale `f` alias from a previous .bashrc: bash expands aliases
# at parse time, so an existing alias would corrupt this function definition.
unalias f 2>/dev/null
unalias mediaconnect proxmoxmediaconnect proxmoxpersonalconnect 2>/dev/null
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
#alias mediaconnect='ssh -X daniel@10.0.0.93'
mediaconnect() {
    ssh daniel@10.0.0.247
}
proxmoxmediaconnect() {
    [[ $(command -v ssh) == /opt/homebrew/bin/ssh* ]] && printf '\033[1;33mPlease ensure your YubiKey is ready, you will need to tap it.\033[0m\n' && ssh root@10.0.0.84 || printf '\033[31mWARNING: ssh is not Homebrew: %s\033[0m\n' "$(command -v ssh)"
}
proxmoxpersonalconnect() {
    [[ $(command -v ssh) == /opt/homebrew/bin/ssh* ]] && printf '\033[1;33mPlease ensure your YubiKey is ready, you will need to tap it.\033[0m\n' && ssh root@10.0.0.226 || printf '\033[31mWARNING: ssh is not Homebrew: %s\033[0m\n' "$(command -v ssh)"
}
export TEST_TOKEN_NOT_REAL="ATATT3xFfGF0-MEGHpdjwsHm3_7n9kjQWns-j6c1eytLrJmJynOlybv5FUXHR2enc5-6eq19OroOzuNRj6l8FCuxVZWVF4T0anCXfZXn42wxxM_JLaXArvGr4H5-dnm1A1ZGnTzbQmqCpBMcMeiAjJp271T_aW_yqttIZIIqpXX4_FPfZlKU-kE=F7651C8D"

alias bashr='source ~/.bash_profile'
alias bbopen='nvim ~/.bash_profile'
alias bopen='nvim ~/.bashrc'
#alias cdcpp='cd ~/src/CPP_LEARN'
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
[ -f "$HOME/.dotfiles/bash/aliases-backup.sh" ] && source "$HOME/.dotfiles/bash/aliases-backup.sh"
alias ..="cd .."
#alias -="cd -"

if [ -f "$HOME/.dotfiles/bash/workflow.sh" ]; then
    source "$HOME/.dotfiles/bash/workflow.sh"
fi

FILE_LINES=/tmp/files_lines.txt
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

#git worktree add -b testworktreebranch /tmp/worktreetemp/
# git worktree list

# External commands & config consumed by nvim (EXTERNAL_BUILD_AND_OPEN_PDF,
# EXTERNAL_PATHS_GLOBAL, NVIM_CD_TARGETS, JIRA_URL). Kept together in one file.
if [ -f ~/.dotfiles/bash/external.sh ]; then
    source "$HOME/.dotfiles/bash/external.sh"
fi

. "$HOME/.cargo/env"
eval "$(zoxide init bash)"
# fzf keybindings for bash: Ctrl-R (history search), Ctrl-T (files), Alt-C (cd)
eval "$(fzf --bash)"
#export PATH=$HOME/.local/bin:$PATH

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
export PATH="/Users/danielbaker/.local/bin:$PATH"

# workspace-switcher shell utilities (prettyprint: format JSON/XML from stdin)
if [ -f "$HOME/.config/workspace-switcher/bin/utils.sh" ]; then
    source "$HOME/.config/workspace-switcher/bin/utils.sh"
fi
