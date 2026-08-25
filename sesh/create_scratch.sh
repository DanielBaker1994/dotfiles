#!/usr/bin/env bash

set -euo pipefail

printf 'Scratch name or path: ' >/dev/tty
IFS= read -r input </dev/tty
input=${input%/}

if [[ -z $input ]]; then
    exit 1
fi

case $input in
    \~) directory=$HOME ;;
    \~/*) directory="$HOME/${input#\~/}" ;;
    /*) directory=$input ;;
    */*) directory="$PWD/$input" ;;
    *) directory="/tmp/$input" ;;
esac

mkdir -p -- "$directory"
directory=$(cd -- "$directory" && pwd -P)
zoxide add "$directory"

printf '%s\n' "$directory"
