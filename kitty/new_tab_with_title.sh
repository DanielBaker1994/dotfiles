#!/bin/bash
# Create a new tab in the current CWD
kitten @ launch --type=tab --cwd=current
# Prompt for title
echo -n "Enter tab title: "
read title
# Set the title of the new tab
kitten @ set-tab-title "$title"
