# External commands & config consumed by nvim via `bash -lc`.
#
# Keep the Lua side in sync: ~/.dotfiles/nvim/lua/bash_external/
# (each of these has a matching module there that prefetches/caches the value).
#
# Sourced by ~/.dotfiles/bash/.bashrc.

# Used by nvim :Jira (lua/bash_external/jira.lua) to build the ticket link.
# The ticket prefix (e.g. JT) is prompted for once by nvim and cached in
# nvim/lua/user/jira_prefix.lua (gitignored) — see lua/user/workspace.lua.
export JIRA_URL="https://sudosignup.atlassian.net"

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
#   prefix= name prefix of each worktree dir (e.g. DOT -> DOT-123); omitted ->
#           the cached Jira prefix. If the dir is itself a single repo (e.g.
#           ~/.dotfiles), prefix matches nothing and the dir itself is the workspace
function NVIM_CD_TARGETS() {
    cat <<EOF
root=$HOME/jira

root=$HOME/.dotfiles
prefix=DOT
top=.
nvim=nvim
bash=bash
EOF
}

# One-time install of the node packages render.mjs needs (mermaid + MathJax,
# ~500MB) into ~/.local/share/markdown_generator — outside the dotfiles so
# git/rg/lazygit never see them. Reinstalls when markdown_generator/package.json
# changes. Uses Google Chrome.app when present instead of downloading Chromium.
function EXTERNAL_MARKDOWN_NODE_SETUP() {
    local src="$DOTDIR/markdown_generator/package.json"
    local dir="${MDGEN_NODE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/markdown_generator}"
    local chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    command -v npm &>/dev/null || {
        echo "markdown: npm not found (brew install node): mermaid + math disabled" >&2
        return 1
    }
    if cmp -s "$src" "$dir/package.json" && [[ -d $dir/node_modules/@mermaid-js/mermaid-cli ]]; then
        return 0
    fi
    echo "markdown: installing mermaid + MathJax into $dir (one time, ~1 min)..." >&2
    mkdir -p "$dir" && cp "$src" "$dir/package.json" || return 1
    if (
        cd "$dir" || exit 1
        [[ -x $chrome ]] && export PUPPETEER_SKIP_DOWNLOAD=1
        npm install --silent --no-audit --no-fund --no-package-lock
    ) >&2; then
        return 0
    fi
    rm -f "$dir/package.json" # so the next build retries
    echo "markdown: npm install failed: mermaid + math disabled for this build" >&2
    return 1
}

# Used by nvim markdown_open (lua/bash_external/build_and_open_pdf.lua).
#   EXTERNAL_BUILD_AND_OPEN_PDF SRC.md OUT   → OUT.html (opened), OUT.pdf, OUT.png
# MDGEN_OPEN=html (default) | pdf | none  picks what gets opened.
# Exit 0 = built; anything on stderr then is a warning worth showing (missing
# image, bad math/diagram). Exit 1 = setup problem, 3 = pandoc/weasyprint failed.
#
# Pipeline: pandoc (gfm + extras) → document.lua (front matter, TOC, labels,
# task lists, callouts) → render.lua (dot/d2/mermaid/math → SVG) → one
# self-contained .html → weasyprint .pdf → background .png. See
# markdown_generator/*.lua headers for the markdown features.
function EXTERNAL_BUILD_AND_OPEN_PDF() {
    local src="$1" out="$2"
    if [[ -z $src || -z $out ]]; then
        printf 'usage: EXTERNAL_BUILD_AND_OPEN_PDF SRC.md OUT_PATH_WITHOUT_EXT\n' >&2
        return 1
    fi
    [[ -f $src ]] || { echo "no such file: $src" >&2; return 1; }
    local t
    for t in pandoc weasyprint; do
        command -v "$t" &>/dev/null || { echo "$t must be installed (brew install $t)" >&2; return 1; }
    done
    local gen="$DOTDIR/markdown_generator"
    local css="$gen/friendly_document_styling.css"
    [[ -f $css ]] || { echo "missing stylesheet: $css" >&2; return 1; }
    [[ -f $NERDFONT_PATH_GLOBAL ]] ||
        echo "warning: Nerd Font not found ($NERDFONT_PATH_GLOBAL): icons will show as boxes" >&2

    # mermaid / math need the node helpers; only bother when the doc might use them
    if grep -qE '^ {0,3}(```|~~~)+ *mermaid|\$' "$src"; then
        EXTERNAL_MARKDOWN_NODE_SETUP || true
    fi

    local html="$out.html" pdf="$out.pdf" png="$out.png" log
    log=$(mktemp) || return 1

    # gfm = what AI tools and GitHub write (alerts, task lists, footnotes,
    # $math$); + definition lists, ::: fenced divs, {.attributes}, image captions.
    # (not +subscript: "~5 min … ~10 min" would turn into subscript)
    # --embed-resources: one self-contained .html you can send, and images are
    # found via --resource-path (the .md's own folder first).
    if ! pandoc -s -t html5 \
        -f gfm+definition_lists+fenced_divs+attributes+implicit_figures \
        --embed-resources \
        --resource-path="$(dirname "$src"):${ASSET_PICTURES_DIRECTORY_GLOBAL:-.}:$gen" \
        -M document-css=false \
        --syntax-highlighting=tango \
        --lua-filter="$gen/document.lua" \
        --lua-filter="$gen/render.lua" \
        --include-in-header="$css" \
        --include-in-header="$gen/screen.css" \
        --include-after-body="$gen/screen.js" \
        -o "$html" "$src" 2>"$log"; then
        echo "pandoc failed:" >&2
        cat "$log" >&2
        rm -f "$log"
        return 3
    fi
    # pandoc warnings (missing image, bad math, failed diagram) → stderr,
    # minus the "Scripting warning at …/render.lua line N column N:" prefix
    grep -v '^\s*$' "$log" |
        sed -E 's/^\[WARNING\] Scripting warning at [^:]+ column [0-9]+: /[WARNING] /' >&2
    [[ ${MDGEN_OPEN:-html} == html ]] && open "$html"

    # --pdf-tags: tagged PDF (reflow / paragraph copy in readers). weasyprint's
    # "Ignored …" / unknown-property chatter is noise; real errors are kept.
    if ! weasyprint --pdf-tags "$html" "$pdf" 2>"$log"; then
        echo "weasyprint failed:" >&2
        cat "$log" >&2
        rm -f "$log"
        return 3
    fi
    # (missing images were already reported by pandoc's --embed-resources;
    # "no required alt description" is a --pdf-tags accessibility nit for ![](x.png))
    grep '^ERROR' "$log" | grep -v -e 'Failed to load image' -e 'no required alt description' |
        sed -E -e 's/^ERROR: /weasyprint: /' -e 's/data:[^",)]{40,}/data:…/g' >&2
    rm -f "$log"
    [[ ${MDGEN_OPEN:-html} == pdf ]] && open "$pdf"

    # PNG at 200 dpi, rasterised from the finished PDF so the pixel size
    # always follows the PDF page size (nothing cut off) and matches the PDF.
    # Writes ONE <out>.png named like the markdown: pages stacked top to bottom
    # (magick), or page 1 alone if ImageMagick is missing.
    # Backgrounded + disowned so it never adds latency to the build.
    if command -v pdftoppm &>/dev/null; then
        (
            tmp_png_dir=$(mktemp -d) &&
                pdftoppm -r 200 -png "$pdf" "$tmp_png_dir/p" &>/dev/null &&
                if command -v magick &>/dev/null; then
                    magick "$tmp_png_dir"/p-*.png -append "$png"
                else
                    pages=("$tmp_png_dir"/p-*.png) && mv "${pages[0]}" "$png"
                fi
            rm -rf "$tmp_png_dir"
        ) &>/dev/null &
        disown 2>/dev/null || true
    else
        echo "pdftoppm not found (brew install poppler); skipping PNG" >&2
    fi
    return 0
}
export -f EXTERNAL_BUILD_AND_OPEN_PDF

# Dump everything nvim needs to run external commands WITHOUT paying the
# login-shell cost every time (lua/bash_external/defs.lua).
#
# Writing OUT_FILE: every function defined in this file (parsed from
# external.sh, so adding a function here is automatically picked up) + the
# env vars the functions reference. The dump is a plain bash file nvim can
# `source` in a fast `bash --noprofile --norc` instead of re-running all of
# .bash_profile.
function EXTERNAL_DEFS_DUMP() {
    local out="${1:?usage: EXTERNAL_DEFS_DUMP OUT_FILE}"
    {
        local f
        while IFS= read -r f; do
            declare -f "$f"
        done < <(sed -nE 's/^function ([A-Za-z_][A-Za-z0-9_]*).*/\1/p' "$DOTDIR/bash/external.sh")
        declare -p DOTDIR NERDFONT_PATH_GLOBAL ASSET_PICTURES_DIRECTORY_GLOBAL 2>/dev/null
    } >"$out"
}
