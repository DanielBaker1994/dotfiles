#!/usr/bin/env bash

set -euo pipefail

printf 'Website URL: ' >/dev/tty
IFS= read -r input </dev/tty
input=${input%/}

if [[ -z $input ]]; then
    exit 1
fi

host="$(printf '%s' "$input" | sed -E 's#^[a-zA-Z]+://##; s#^www\.##i; s#/.*$##')"
label="$(printf '%s' "$host" | cut -d. -f1)"
label="${label^}"

win="Browser${label}"

tmux new-window -n "$win" "$HOME/.local/bin/terminal-browser open '$input'; exec \$SHELL"