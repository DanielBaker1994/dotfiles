#!/usr/bin/env bash
alias bashr='source ~/.bashrc'
alias bbopen='nvim ~/.bash_profile'
alias bopen='nvim ~/.bashrc'
alias cdcpp='cd ~/src/CPP_LEARN'
alias topen='nvim ~/.tmux.conf'
alias tsource='tmux source ~/.tmux.conf'
alias vi='nvim'
alias vim='nvim'
alias vopen='nvim ~/.config/nvim/init.lua'



parse_git_branch () 
{ 
    git branch 2> /dev/null | sed -n -e 's/^* \(.*\)/\1/p'
}
tmux_quick_files () 
{ 
    local items=(
        "tmux-dev-notes-temp|$HOME/Desktop/DevNotes/Workspace/tmux_window_dev_notes.txt"
        "dev_notes_important|$HOME/Desktop/DevNotes/Workspace/dev_notes_important.txt"
        "tickets|$HOME/Desktop/DevNotes/Workspace/CurrentTickets.txt"
        "jiras_all|$HOME/Desktop/DevNotes/Jira/jira_danbaker_tickets.txt"
        "open_terminal|__ACTION__open_terminal"
    )

    local selected_key
    selected_key=$(printf '%s\n' "${items[@]}" | fzf --reverse --header "Select a file alias or action")
    [ -z "$selected_key" ] && return 0


    if [[ -n "$selected_key" ]]; then
        if [[ -n "${file_map[$selected_key]}" ]]; then
            file_path="${file_map[$selected_key]}";
            cd "$(dirname "$file_path")";
            nvim "$file_path";
        else
            if [[ -n "${action_map[$selected_key]}" ]]; then
                action="${action_map[$selected_key]}";
                if [[ "$action" == "open_terminal" ]]; then
                    tmux new-window;
                fi;
            else
                echo "Invalid selection";
            fi;
        fi;
    fi
}

