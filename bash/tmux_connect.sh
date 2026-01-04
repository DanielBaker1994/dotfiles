#!/usr/bin/env bash

#Dont delete me, it is used by tmux
function EXTERNAL_TMUX_WINDOW_SWITCH() {
    tmux list-windows -a -F '#S:#I:#W' | fzf | awk -F: '{print "tmux switch-client -t " $1 "; tmux select-window -t " $1 ":" $2}' | sh
}

function EXTERNAL_TMUX_SESSION_SWITCH() {
    tmux list-sessions -F '#S:#{session_windows}' | fzf | awk -F: '{print "tmux switch-client -t " $1 }' | sh
}

function tmux_new_pane_existing_window() {
    local -n tmux_info=$1
    tmux split-pane -d -c "${tmux_info["START_DIRECTORY"]}" -t "${tmux_info["SESSION_TARGET"]}" -P -F "#{pane_id}"
}

function tmux_new_window_new_session() {
    local -n tmux_info=$1
    tmux new-session -d -c "${tmux_info["START_DIRECTORY"]}" -s "${tmux_info["SESSION_NAME"]}" -n "${tmux_info["WINDOW_NAME"]}" -P -F "#{pane_id}"
}

function tmux_new_window_existing_session() {
    local -n tmux_info=$1
    tmux new-window -d -c "${tmux_info["START_DIRECTORY"]}" -n "${tmux_info["WINDOW_NAME"]}" -t "${tmux_info["SESSION_NAME"]}" -P -F "#{pane_id}"
}

function tmux_send_keys_by_pane_id() {
    local -n tmux_info=$1
    tmux send-keys -t "${tmux_info["PANE_ID"]}" "${tmux_info["SHELL_START_COMMAND"]}" Enter
}

function restore() {
    mapfile -t target_files < <(cat ~/.dotfiles/bash/tmux_sessions.txt)
    declare -A tmux_session_line
    for item in "${target_files[@]}"; do
        IFS=',' read -r -a my_array <<<"$item"
        declare -A tmux_session_line
        tmux_session_line["SESSION_NAME"]="${my_array[0]}"
        tmux_session_line["WINDOW_NAME"]="${my_array[1]}"
        tmux_session_line["SESSION_TARGET"]="${my_array[0]}":"${my_array[1]}"
        tmux_session_line["START_DIRECTORY"]="${my_array[2]@P}"
        tmux_session_line["SHELL_START_COMMAND"]="${my_array[3]}"
        local pane_id=""
        if tmux has-session -t="${tmux_session_line["SESSION_TARGET"]}" 2>/dev/null; then
            pane_id=$(tmux_new_pane_existing_window tmux_session_line)
        elif tmux has-session -t="${tmux_session_line["SESSION_NAME"]}" 2>/dev/null; then
            pane_id=$(tmux_new_window_existing_session tmux_session_line)
        else
            pane_id=$(tmux_new_window_new_session tmux_session_line)
        fi
        tmux_session_line["PANE_ID"]="$pane_id"
        tmux_send_keys_by_pane_id tmux_session_line
    done

}

export -f EXTERNAL_TMUX_WINDOW_SWITCH
export -f EXTERNAL_TMUX_SESSION_SWITCH
