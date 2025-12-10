kitty @ ls | jq -r '.[].tabs[]'


kitten @ ls | jq -r '.[].tabs[] | .windows[] | select(.is_active == true)'
kitten @ ls | jq -r '.[].tabs[] | .windows[]  | select(.is_active == true) | .id'
kitten @ ls | jq -r 'select(.[].tabs[].windows[].is_active == true)'


kitten @ ls | jq '.[].tabs[] | select(.windows[] | select(.is_self == true))'


# titles for this active tab
kitten @ ls | jq '.[].tabs[] | select(any(.windows[]; .is_self == true))' | jq '.windows[].title'
# all titles
kitten @ ls | jq '.[].tabs[] | .windows[].title'



kitten @ ls | jq '.[].tabs[] | select(.windows[].is_self == true and .windows[].is_focused == true)'



{
  "active_window_history": [
    50,
    1
  ],
  "enabled_layouts": [
    "fat",
    "grid",
    "horizontal",
    "splits",
    "stack",
    "tall",
    "vertical"
  ],
  "groups": [
    {
      "id": 1,
      "windows": [
        1
      ]
    },
    {
      "id": 48,
      "windows": [
        50
      ]
    }
  ],
  "id": 1,
  "is_active": true,
  "is_focused": true,
  "layout": "fat",
  "layout_opts": {
    "bias": 50,
    "full_size": 1,
    "mirrored": "n"
  },
  "layout_state": {
    "all_windows": {
      "active_group_history": [
        35,
        36,
        38,
        46,
        48,
        1
      ],
      "active_group_idx": 1,
      "window_groups": [
        {
          "id": 1,
          "window_ids": [
            1
          ]
        },
        {
          "id": 48,
          "window_ids": [
            50
          ]
        }
      ]
    },
    "biased_map": {},
    "class": "Fat",
    "main_bias": [
      0.5,
      0.5
    ],
    "opts": {
      "bias": 50,
      "full_size": 1,
      "mirrored": "n"
    }
  },
  "title": "bash",
  "windows": [
    {
      "at_prompt": false,
      "cmdline": [
        "/opt/homebrew/bin/bash"
      ],
      "columns": 155,
      "created_at": 1767016007133689000,
      "cwd": "/Users/danielbaker",
      "env": {
        "KITTY_WINDOW_ID": "1",
        "MANPATH": "/Applications/kitty.app/Contents/Resources/man:"
      },
      "foreground_processes": [
        {
          "cmdline": [
            "nvim",
            "jqtest.jq"
          ],
          "cwd": "/Users/danielbaker/.dotfiles/kitty",
          "pid": 78467
        }
      ],
      "id": 1,
      "in_alternate_screen": true,
      "is_active": false,
      "is_focused": false,
      "is_self": false,
      "last_cmd_exit_status": 0,
      "last_reported_cmdline": "vim jqtest.jq ",
      "lines": 25,
      "pid": 71267,
      "title": "tab1",
      "user_vars": {}
    },
    {
      "at_prompt": false,
      "cmdline": [
        "/opt/homebrew/bin/bash"
      ],
      "columns": 155,
      "created_at": 1767020412738632000,
      "cwd": "/Users/danielbaker/.dotfiles/kitty",
      "env": {
        "KITTY_WINDOW_ID": "50"
      },
      "foreground_processes": [
        {
          "cmdline": [
            "/Applications/kitty.app/Contents/MacOS/kitten",
            "@",
            "ls"
          ],
          "cwd": "/Users/danielbaker",
          "pid": 78906
        },
        {
          "cmdline": [
            "perl",
            "-pe",
            "chomp if eof"
          ],
          "cwd": "/Users/danielbaker",
          "pid": 78908
        },
        {
          "cmdline": [
            "pbcopy"
          ],
          "cwd": "/Users/danielbaker",
          "pid": 78909
        },
        {
          "cmdline": [
            "jq",
            ".[].tabs[] | select(any(.windows[]; .is_self == true))"
          ],
          "cwd": "/Users/danielbaker",
          "pid": 78907
        }
      ],
      "id": 50,
      "in_alternate_screen": false,
      "is_active": true,
      "is_focused": true,
      "is_self": true,
      "last_cmd_exit_status": 0,
      "last_reported_cmdline": "kitten @ ls | jq '.[].tabs[] | select(any(.windows[]; .is_self == true))' | pbcopy",
      "lines": 26,
      "pid": 76712,
      "title": "bash",
      "user_vars": {}
    }
  ]
}
