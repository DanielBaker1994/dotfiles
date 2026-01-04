#!/usr/bin/env bash

target_session="man"
while true; do
    for pane in $(tmux list-windows -t $target_session -F "#{pane_id}"); do
        tmux send-keys -t $pane "echo 'keep alive....'" Enter
    done
    sleep 14m
done
