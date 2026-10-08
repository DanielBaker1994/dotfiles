#!/usr/bin/env bash

# Port of tmux_connect.sh's connect() for herdr.
# tmux session -> herdr workspace, tmux window -> herdr tab, tmux pane -> herdr pane.
# IDs are opaque (w1 / w1:t1 / w1:p1), so labels are resolved from `* list` JSON.
#
# before (tmux):
#   tmux new-window -a -d -c /tmp -n "$host" -t ssh_dev -P -F '#{pane_id}'   # -> @1
# after (herdr):
#   herdr tab create --workspace wS --cwd /tmp --label "$host" --no-focus | jq -r '.result.root_pane.pane_id'   # -> wS:t1 / wS:p1

function _herdr_workspace_id_by_label() {
    local label="$1"
    herdr workspace list | jq -r --arg l "$label" \
        '.result.workspaces[] | select(.label == $l) | .workspace_id' | head -n1
}

function _herdr_tab_id_by_label() {
    local label="$1" workspace_id="$2"
    herdr tab list --workspace "$workspace_id" | jq -r --arg l "$label" \
        '.result.tabs[] | select(.label == $l) | .tab_id' | head -n1
}

function _herdr_tab_root_pane_id() {
    local tab_id="$1" workspace_id="$2"
    herdr pane list --workspace "$workspace_id" | jq -r --arg t "$tab_id" \
        '.result.panes[] | select(.tab_id == $t) | .pane_id' | head -n1
}

function herdr_new_pane_existing_tab() {
    local -n tm_config=$1
    herdr pane split "${tm_config["TARGET_PANE_ID"]}" \
        --direction down \
        --cwd "${tm_config["START_DIRECTORY"]}" \
        --no-focus | jq -r '.result.pane.pane_id'
}

# Emits "<tab_id> <root_pane_id>".
function herdr_new_tab_existing_workspace() {
    local -n tm_config=$1
    herdr tab create \
        --workspace "${tm_config["WORKSPACE_ID"]}" \
        --cwd "${tm_config["START_DIRECTORY"]}" \
        --label "${tm_config["WINDOW_NAME"]}" \
        --no-focus | jq -r '.result.tab.tab_id + " " + .result.root_pane.pane_id'
}

# Emits "<workspace_id> <tab_id> <root_pane_id>".
function herdr_new_workspace() {
    local -n tm_config=$1
    herdr workspace create \
        --cwd "${tm_config["START_DIRECTORY"]}" \
        --label "${tm_config["SESSION_NAME"]}" \
        --no-focus | jq -r '.result.workspace.workspace_id + " " + .result.tab.tab_id + " " + .result.root_pane.pane_id'
}

function _herdr_send_keys_by_pane_id() {
    local -n tm_config=$1
    [[ -n "${tm_config["SHELL_START_COMMAND"]}" ]] || return 0
    herdr pane run "${tm_config["PANE_ID"]}" "${tm_config["SHELL_START_COMMAND"]}"
}

function _herdr_window_create_logic() {
    local -n window_create_config=$1
    local pane_id=""

    if [[ -n "${window_create_config["TAB_ID"]}" ]]; then
        pane_id=$(herdr_new_pane_existing_tab window_create_config)
    elif [[ -n "${window_create_config["WORKSPACE_ID"]}" ]]; then
        read -r tab_id pane_id <<<"$(herdr_new_tab_existing_workspace window_create_config)"
        window_create_config["TAB_ID"]="$tab_id"
    else
        read -r workspace_id tab_id pane_id <<<"$(herdr_new_workspace window_create_config)"
        window_create_config["WORKSPACE_ID"]="$workspace_id"
        window_create_config["TAB_ID"]="$tab_id"
        # workspace create does not label its tab, so name it after the host.
        herdr tab rename "$tab_id" "${window_create_config["WINDOW_NAME"]}" >/dev/null
    fi

    # Subsequent splits target the pane we just made (tmux makes it active).
    window_create_config["TARGET_PANE_ID"]="$pane_id"
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

    if [[ "${HERDR_ENV:-}" != "1" ]]; then
        echo "Not running inside Herdr (HERDR_ENV != 1)."
        return 1
    fi

    declare -A connect_config
    connect_config["START_DIRECTORY"]="/tmp/"
    connect_config["SESSION_NAME"]="ssh_dev"
    connect_config["WINDOW_NAME"]="${host_alias}"
    connect_config["WORKSPACE_ID"]=$(_herdr_workspace_id_by_label "${connect_config["SESSION_NAME"]}")
    if [[ -n "${connect_config["WORKSPACE_ID"]}" ]]; then
        connect_config["TAB_ID"]=$(_herdr_tab_id_by_label "${connect_config["WINDOW_NAME"]}" "${connect_config["WORKSPACE_ID"]}")
    fi
    if [[ -n "${connect_config["TAB_ID"]}" ]]; then
        connect_config["TARGET_PANE_ID"]=$(_herdr_tab_root_pane_id "${connect_config["TAB_ID"]}" "${connect_config["WORKSPACE_ID"]}")
    fi
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

    if [[ $2 != "here" ]] && [[ -n "${connect_config["TAB_ID"]}" ]]; then
        herdr tab close "${connect_config["TAB_ID"]}"
        connect_config["TAB_ID"]=""
        connect_config["TARGET_PANE_ID"]=""
        # herdr may drop the workspace when its last tab closes.
        connect_config["WORKSPACE_ID"]=$(_herdr_workspace_id_by_label "${connect_config["SESSION_NAME"]}")
    fi

    for ((i = 0; i < panes; i++)); do
        _herdr_window_create_logic connect_config
        _herdr_send_keys_by_pane_id connect_config
    done
}
