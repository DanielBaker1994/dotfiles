#!/usr/bin/env bash

#Dont delete me, it is used by tmux
function EXTERNAL_TMUX_WINDOW_SWITCH() {
    tmux list-windows -a -F '#S:#I:#W' | fzf --prompt "Switch to window > " | awk -F: '{print "tmux switch-client -t " $1 "; tmux select-window -t " $1 ":" $2}' | sh
}

function EXTERNAL_TMUX_SESSION_SWITCH() {
    tmux list-sessions -F '#S:#{session_windows}' | fzf --prompt "Switch to session > " | awk -F: '{print "tmux switch-client -t " $1 }' | sh
}

function TMUX_SCRATCH_TOGGLE() {
    created_pane=$(tmux split-window -d -P -F "#{pane_id}")
    tmux send-keys -t ${created_pane} "echo intmux" Enter
}

function tmux_new_pane_existing_window() {
    local -n tm_config=$1
    tmux split-pane -d -c "${tm_config["START_DIRECTORY"]}" -t "${tm_config["SESSION_TARGET"]}" -P -F "#{pane_id}"
}

function tmux_new_window_new_session() {
    local -n tm_config=$1
    tmux new-session -d -c "${tm_config["START_DIRECTORY"]}" -s "${tm_config["SESSION_NAME"]}" -n "${tm_config["WINDOW_NAME"]}" -P -F "#{pane_id}"
}

function tmux_new_window_existing_session() {
    local -n tm_config=$1
    tmux new-window -a -d -c "${tm_config["START_DIRECTORY"]}" -n "${tm_config["WINDOW_NAME"]}" -t "${tm_config["SESSION_NAME"]}" -P -F "#{pane_id}"
}

function _tmux_send_keys_by_pane_id() {
    local -n tm_config=$1
    tmux send-keys -t "${tm_config["PANE_ID"]}" "${tm_config["SHELL_START_COMMAND"]}" Enter
}

function _tmux_window_create_logic() {
    local -n window_create_config=$1
    local pane_id=""
    if tmux has-session -t="${window_create_config["SESSION_TARGET"]}" 2>/dev/null; then
        pane_id=$(tmux_new_pane_existing_window window_create_config)
    elif tmux has-session -t="${window_create_config["SESSION_NAME"]}" 2>/dev/null; then
        pane_id=$(tmux_new_window_existing_session window_create_config)
    else
        pane_id=$(tmux_new_window_new_session window_create_config)
    fi
    window_create_config["PANE_ID"]="$pane_id"
}

function connect() {
    local host_alias="$1"
    local panes=${2:-2}
    if [[ $2 == "here" ]]; then
        panes=1
    fi

    if [ "$panes" -ne "$panes" ] 2>/dev/null; then
        echo "Pane supplied is not a number."
        return 1
    fi

    declare -A connect_config
    connect_config["START_DIRECTORY"]="/tmp/"
    connect_config["SESSION_NAME"]="ssh_dev"
    connect_config["WINDOW_NAME"]="${host_alias}"
    connect_config["SESSION_TARGET"]="${connect_config["SESSION_NAME"]}":"${connect_config["WINDOW_NAME"]}"
    case "$host_alias" in
    ALIASHOST1)
        connect_config["SHELL_START_COMMAND"]="echo ALIASHOST1"
        ;;
    ALIASHOST2)
        connect_config["SHELL_START_COMMAND"]="echo ALIASHOST2"
        ;;
    *)
        :
        ;;
    esac

    if [[ $2 != "here" ]] && tmux has-session -t="${connect_config["SESSION_TARGET"]}" 2>/dev/null; then
        tmux kill-window -t "${connect_config["SESSION_TARGET"]}"
    fi
    for ((i = 0; i < panes; i++)); do
        _tmux_window_create_logic connect_config
        _tmux_send_keys_by_pane_id connect_config
    done
}

function restore() {
    local restore_file=${1:-~/.dotfiles/bash/tmux_sessions.txt}
    [[ ! -f $restore_file ]] && echo "Not a file, exiting" && return
    mapfile -t target_files < <(cat "$restore_file")
    declare -A restore_config
    for item in "${target_files[@]}"; do
        IFS=',' read -r -a my_array <<<"$item"
        declare -A restore_config
        restore_config["SESSION_NAME"]="${my_array[0]}"
        restore_config["WINDOW_NAME"]="${my_array[1]}"
        restore_config["SESSION_TARGET"]="${my_array[0]}":"${my_array[1]}"
        restore_config["START_DIRECTORY"]="${my_array[2]@P}"
        restore_config["SHELL_START_COMMAND"]="${my_array[3]}"
        if tmux has-session -t="${restore_config["SESSION_TARGET"]}" 2>/dev/null; then
            echo "Already exists ${restore_config["SESSION_TARGET"]}. Skip recreating..."
            continue
        fi
        _tmux_window_create_logic restore_config
        _tmux_send_keys_by_pane_id restore_config
    done
}

export -f EXTERNAL_TMUX_WINDOW_SWITCH
export -f EXTERNAL_TMUX_SESSION_SWITCH
