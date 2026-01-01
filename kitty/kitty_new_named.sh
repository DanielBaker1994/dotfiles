#!/opt/homebrew/bin/bash

function close_this_window() {
    kitten @ close-window --match "title:promptwindow"
}

trap close_this_window SIGINT
firstSplitId=""
if [[ "$1" == "tab" ]]; then

    kitten @ set-window-title "promptwindow"
    read -rp "Create New Tab With Name:" new_tab
    if [[ -z "$new_tab" || "${new_tab,,}" == 'q' ]]; then
        close_this_window
    else
        firstSplitId=$(kitten @ launch --type=tab --cwd=current --tab_title="$new_tab")
        kitten @ set-window-title --match "id:$firstSplitId" "${new_tab}_1"
        kitty @ focus-tab --match id:"$firstSplitId"
    fi

    close_this_window
fi
