#!/opt/homebrew/bin/bash
kitten @ set-window-title "promptwindow"

function close_this_window() {
    kitten @ close-window --match "title:promptwindow"
}

trap close_this_window SIGINT
firstSplitId=""
if [[ "$1" == "tab" ]]; then

    read -rp "Create New Tab With Name:" new_tab
    if [[ -z "$new_tab" || "${new_tab,,}" == 'q' ]]; then
        close_this_window
    else
        firstSplitId=$(kitten @ launch --type=tab --cwd=current --tab_title="$new_tab")
        kitten @ set-window-title --match "id:$firstSplitId" "${new_tab}_1"
        kitty @ focus-tab --match id:"$firstSplitId"
    fi

    #active_window=""
    #active_window=$(kitten @ ls | jq '.[].tabs[] | select(.windows[].is_self == true and .windows[].is_focused== true) | .title')
fi
close_this_window
