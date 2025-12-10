#!/usr/bin/env bash
JAVA_HOME=/Library/Java/JavaVirtualMachines/temurin-23.jdk/Contents/Home
PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH

function tmux_window_switch () {
    echo hellohere > /tmp/out
    tmux list-windows -a -F '#S:#I:#W' | fzf | awk -F: '{print "tmux switch-client -t " $1 "; tmux select-window -t " $1 ":" $2}' | sh
}

source ~/.bashrc
