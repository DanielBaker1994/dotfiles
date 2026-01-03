#!/usr/bin/env bash

#Dont delete me, it is used by tmux
function EXTERNAL_TMUX_WINDOW_SWITCH() {
    tmux list-windows -a -F '#S:#I:#W' | fzf | awk -F: '{print "tmux switch-client -t " $1 "; tmux select-window -t " $1 ":" $2}' | sh
}

function EXTERNAL_TMUX_SESSION_SWITCH() {
    tmux list-sessions -F '#S:#{session_windows}' | fzf | awk -F: '{print "tmux switch-client -t " $1 }' | sh
}

function tmux_new_split() {
    :
}

function tmux_new_session() {
    :

    #new-session [-AdDEPX] [-c start-directory] [-e environment] [-f flags] [-F format] [-n window-name] [-s session-name] [-t group-name] [-x width] [-y height] [shell-command [argument ...]]

}

#New window on non existant session
#tmux new-session -d -c /tmp/ -s sessionnew -n windownew.1 -t sessionnew:windownew.1
#tmux split-pane -d -c /tmp/ -t sessionnew:windownew.1

#New window on existant session
#tmux new-window -d -c /tmp/ -n windownew.2 -t sessionnew
#tmux split-pane -d -c /tmp/ -t sessionnew:windownew.2

#tmux new-session -d -c /tmp/ -s sessionnew -n windownew.1
#tmux split-pane -d -c /tmp/ -t sessionnew:windownew.1
#tmux switch-client -t sessionnew:windownew.1

#list-sessions
#list-windows

export -f EXTERNAL_TMUX_WINDOW_SWITCH
export -f EXTERNAL_TMUX_SESSION_SWITCH
