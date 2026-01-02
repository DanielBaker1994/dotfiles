#!/usr/bin/env bash
alias f='fzf'

alias bashr='source ~/.bash_profile'
alias bbopen='nvim ~/.bash_profile'
alias bopen='nvim ~/.bashrc'
#alias cdkitty='cd ~/.config/kitty'
#alias cdcpp='cd ~/src/CPP_LEARN'
alias kopen='nvim ~/.config/kitty/kitty.conf'
alias topen='nvim ~/.tmux.conf'
alias tsource='tmux source ~/.tmux.conf'
function ksource() {
    kill -SIGUSR1 $KITTY_PID
}
alias vi='nvim'
alias vim='nvim'
alias vopen='nvim ~/.config/nvim/init.lua'
alias bat='bat --no-pager'
alias clear="TERM=xterm /usr/bin/clear" #terminals database is inaccessible
alias cls="clear && printf '\e[3J'"
alias pbcopy="perl -pe 'chomp if eof' | pbcopy"
FILE_LINES=/tmp/files_lines.txt
parse_git_branch() {
    git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
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

# function kittyconnectdev() {
#     local new_tab="$1"
#     local firstSplitId secondSplitId
#     firstSplitId=$(kitten @ launch --type=tab --tab_title="$new_tab")
#     secondSplitId=$(kitten @ new-window --match "title:^$new_tab")
#     goto_session ~/.config/kitty/code_session/ssh_dev.kitty-session
#
#     kitten @ set-window-title --match "id:$firstSplitId" "${new_tab}_1"
#     kitten @ set-window-title --match "id:$secondSplitId" "${new_tab}_2"
#
#     echo "echo hellowindow1" | kitten @ send-text --match "id:$firstSplitId" --stdin
#     echo "echo hellowindow2" | kitten @ send-text --match "id:$secondSplitId" --stdin
#
# }

function connect() {
    declare -A server_map
    server_map["HOST1"]="kittyconnectdev"
    server_map["HOST2"]="kittyconnectdev"
    local host="${server_map[$1]}"

    if [[ $host != "" ]]; then
        ($host "$1")
    fi
}

function killshellcheck() {
    ps -ef | grep -i shellcheck | awk -F ' ' '{print $2}' | xargs kill -9
}

filepathsquick() {
    mapfile files < <(eval EXTERNAL_PATHS_GLOBAL)
    file_select=$(printf "%s\n" ${files[*]} | fzf --reverse --header "Select a file alias or action")
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

#Dont delete me, it is used by tmux
function EXTERNAL_TMUX_WINDOW_SWITCH() {
    tmux list-windows -a -F '#S:#I:#W' | fzf | awk -F: '{print "tmux switch-client -t " $1 "; tmux select-window -t " $1 ":" $2}' | sh
}

function EXTERNAL_BUILD_AND_OPEN_PDF() {
    command -v pandoc &>/dev/null || {
        echo "pandoc must be installed"
        return 1
    }
    command -v weasyprint &>/dev/null || {
        echo "weasyprint must be installed"
        return 1
    }

    local markdown_admontion_file="$DOTDIR/markdown_generator/admonition.lua"
    local markdown_css_styling="$DOTDIR/markdown_generator/friendly_document_styling.css"
    if [[ ! -f "$NERDFONT_PATH_GLOBAL" || ! -f "$markdown_admontion_file" || ! -f "$markdown_css_styling" ]]; then
        echo "One or more required resources are missing html_styling: $NERDFONT_PATH_GLOBAL $markdown_admontion_file $markdown_css_styling"
        return 1
    fi

    local markdown_source="$1" pdf_output_path="$2"
    if [ -z "$markdown_source" ] || [ -z "$pdf_output_path" ]; then
        printf 'usage: build_and_open_pdf markdown_source RESOURCE_PATH OUT_PATH\n' >&2
        return 1
    fi
    previews=$(ps -ef | pgrep "Preview" 2>/dev/null || true)
    if [[ -n "$previews" ]]; then
        while IFS= read -r item; do
            [[ -n "$item" ]] && kill -9 "$item"
        done <<<"$previews"
    fi

    pdf_file="${pdf_output_path}.pdf"
    base_noext="$pdf_output_path"
    html_tmp="${base_noext}.html"
    if [[ -f $html_tmp ]]; then
        rm "$html_tmp"
    fi
    if pandoc -s -f markdown+raw_html -t html5 \
        --resource-path="$ASSET_PICTURES_DIRECTORY_GLOBAL:$DOTDIR/markdown_generator" \
        --lua-filter="$markdown_admontion_file" \
        --syntax-definition="$DOTDIR/markdown_generator/vim.xml" \
        --include-in-header="$markdown_css_styling" \
        -o "$html_tmp" "$markdown_source"; then
        open "$html_tmp"
    else
        echo "Pandoc failed"
        return 3
    fi

    weasyprint "$html_tmp" "$pdf_file" || {
        echo "weasyprint failed"
        return 3
    }
    killshellcheck

    return 0
}

export -f EXTERNAL_TMUX_WINDOW_SWITCH
. "$HOME/.cargo/env"
