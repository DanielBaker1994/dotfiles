# External commands & config consumed by nvim via `bash -lc`.
#
# Keep the Lua side in sync: ~/.dotfiles/nvim/lua/bash_external/
# (each of these has a matching module there that prefetches/caches the value).
#
# Sourced by both ~/.dotfiles/bash/.bash_profile and ~/.dotfiles/bash/.bashrc.

# Used by nvim :Jira (lua/bash_external/jira.lua) to build the ticket link.
export JIRA_NAME_PREFIX="JT"
export JIRA_URL="https://your-jira.atlassian.net"

# Used by nvim <leader>pi (lua/bash_external/asset_pictures_dir.lua).
# (ASSET_PICTURES_DIRECTORY_GLOBAL is exported in .bash_profile.)

# Used by nvim Telescope greps (lua/bash_external/external_paths.lua).
# Specifying dot files is an ugly trick to show hidden files in rip grep
# without having to enable all of them.
function EXTERNAL_PATHS_GLOBAL() {
    quickpaths=(
        "$DOTDIR"
        "$DOTDIR/bash/.bashrc"
        "$DOTDIR/bash/.inputrc"
        "$DOTDIR/bash/.bash_profile"
        "$DOTDIR/bash/external.sh"
        "$DOTDIR/clang/.clang-format"
        "$DOTDIR/tmux/.tmux.conf"
        "$DOTDIR/git/.gitconfig"
    )
    echo "${quickpaths[@]}"
}

# Used by nvim Cd targets (lua/bash_external/cd_targets.lua).
# Each workspace root is a block of `key=value` lines separated by a blank line:
#   root=   base dir where this workspace lives (worktrees live directly inside)
#   prefix= name prefix of each worktree dir (e.g. JT -> JT-123); if the dir is
#           itself a single repo (e.g. ~/.dotfiles), prefix matches nothing and
#           the dir itself is treated as the workspace
#   <name>=<subpath>   cd shortcut, relative to the matched workspace
function NVIM_CD_TARGETS() {
    cat <<EOF
root=$HOME/jira
prefix=JT
top=.
cpp=cpp

root=$HOME/.dotfiles
prefix=DOT
top=.
nvim=nvim
bash=bash
EOF
}

# Used by nvim markdown_open (lua/bash_external/build_and_open_pdf.lua).
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
        --syntax-highlighting=tango \
        -V lang=en \
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
export -f EXTERNAL_BUILD_AND_OPEN_PDF

# Dump everything nvim needs to run external commands WITHOUT paying the
# login-shell cost every time (lua/bash_external/defs.lua).
#
# Writing OUT_FILE: every function defined in this file (parsed from
# external.sh, so adding a function here is automatically picked up) + the
# one dependency defined in .bashrc (killshellcheck) + the env vars the
# functions reference. The dump is a plain bash file nvim can `source` in a
# fast `bash --noprofile --norc` instead of re-running all of .bash_profile.
function EXTERNAL_DEFS_DUMP() {
    local out="${1:?usage: EXTERNAL_DEFS_DUMP OUT_FILE}"
    {
        local f
        while IFS= read -r f; do
            declare -f "$f"
        done < <(sed -nE 's/^function ([A-Za-z_][A-Za-z0-9_]*).*/\1/p' "$DOTDIR/bash/external.sh")
        declare -f killshellcheck 2>/dev/null
        declare -p DOTDIR NERDFONT_PATH_GLOBAL ASSET_PICTURES_DIRECTORY_GLOBAL 2>/dev/null
    } > "$out"
}