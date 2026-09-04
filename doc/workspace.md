# Daniel Workspace Documents
Setting up workspace and suggested commands.

```{.bash}
# For neovim easier now to ~/cd to workspace
cd ~
ln -s ~/src/cpp_workspace ~/cpp
ln -s ~/src/java_workspace ~/java
ln -s ~/src/root_workspace ~/root
```



```{.vim}
# Telescope filter files. Rip grep create inclusive OR.
# Note two spaces folowing target string.
teststring  **.cpp **.h

# Terminal open. Toggles terminal
<leader>to

#  Search my neovim and quick files
<leader>sn


#  Markdown Open. Must be on a .md file.
<leader>mdo
```






> [!INFO]
> Code blocks like \"vim\" do not exist in pandoc. They can be added by passing a syntax definition.
>
> A valid XML style file can be copied and renamed to the new type:
>
> \--syntax-definition=\"$HOME/.config/markdown_generator/vim.xml\"
>
> Github below:
>
> https://github.com/KDE/syntax-highlighting/blob/master/data/syntax/bash.xml
>
> A language block needs to match the filename. It does not seem possible to map multiple languages to the same file, so you'll likely have to copy the file and update the respective name and language for more.
>
> \<language name=\"vim\" \>



> [!INFO]
> iTerm2 window can be hidden like Kitty.

![](/Users/danielbaker/.dotfiles/doc/hiding_menu_bar.png)

---

# AeroSpace + SketchyBar Status Bar

Vertical right-edge status bar, ported from omerxx/dotfiles on 2026-09-06.
Deploy with `./workspace_setup.sh`
(symlinks everything, installs deps, hides the menu bar, starts services).
Last verified: 2026-09-06, macOS 26.6.2, sketchybar 2.24.0, AeroSpace.

## Install / bootstrap

```bash
# deps
brew tap felixkratz/formulae && brew install sketchybar
brew install --cask font-sketchybar-app-font      # brand-glyph ligatures (:microsoft_outlook:, ...)
# workspace renderer is plain shell: plugins/aerospacer.sh
# icon map artifacts live in sketchybar/sketchybar-app-font/dist (manage_icons.sh)
#   upstream: https://github.com/kvndrsslr/sketchybar-app-font

# symlinks (workspace_setup.sh does these)
ln -s ~/.dotfiles/sketchybar ~/.config/sketchybar
ln -s ~/.dotfiles/aerospace/.aerospace.toml ~/.aerospace.toml

# hide native menu bar
defaults write NSGlobalDomain _HIHideMenuBar -bool true && killall Finder
# (macOS 26 GUI equiv: Settings > Control Center > "Automatically hide and show the menu bar")

brew services start sketchybar      # reload after edits: brew services restart sketchybar
```

## Workspace switcher (fzf-free Tk popup)

`aerospace/workspace_switcher.{py,sh}` — native Tk popup themed like sketchybar
(themed from `colors.sh` / `aerospacer.sh`), bound via karabiner
(`karabiner/karabiner.json` -> `workspace_switcher.sh`, which starts the .py or
sends it a toggle flag). Needs:
- `brew install pillow`      # PIL: rounded-corner bg, app icons (shebang = /opt/homebrew/bin/python3)
- Hack Nerd Font (installed above) for the "?" fallback glyph — optional, degrades to default font
- caches app icons under `~/.cache/workspace-switcher/`

## Karabiner (Hyper key + switcher binding)

`brew install --cask karabiner-elements`, then symlink + activate the extension:
- `ln -s ~/.dotfiles/karabiner ~/.config/karabiner`
- caps_lock -> Hyper (Cmd+Ctrl+Opt+Shift); Hyper+S -> `workspace_switcher.sh`
- System Settings → Privacy & Security → allow the blocked Karabiner system software, restart (see bottom of this doc + `doc/karabinerinstall.png`)

## Disabled on purpose

- **Separate Spaces per display**: `defaults write com.apple.spaces spans-displays -bool true`
  (all monitors share one workspace set; AeroSpace recommends this for stable focus —
  requires logout/login to take effect; set in `workspace_setup.sh`).
- **Ghostty**: `mouse-hide-while-typing` and the `custom-shader` soft-trail are commented out
  (`ghostty/config.ghostty`).
- **Sketchybar**: `icons.sh` no longer sourced (`sketchybarrc`); the Hack Nerd `separator`
  item removed (`plugins/aerospacer.sh`).
- **AeroSpace floating rules**: Flameshot (`org.flameshot`) floats; the Raycast launcher is
  auto-ignored (dialog heuristic, >= 0.18.3) so it needs no rule.

## Config layout (`~/.config/sketchybar` -> `~/.dotfiles/sketchybar`)

- `sketchybarrc` — entry point; bar settings + defaults, sources `plugins/aerospacer.sh`
- `colors.sh` — palette (sourced by `aerospacer.sh` and the workspace switcher)
- `plugins/aerospacer.sh` — builds the space pills and moves the highlight
- `manage_icons.sh` — manual utility to edit the app-glyph map
- `sketchybar-app-font/dist/icon_map.json` — app-glyph lookups (read by `aerospacer.sh`)

## App icon font management (no repo-in-repo)

The full `kvndrsslr/sketchybar-app-font` source repo is **not vendored** — it's a git
repo-in-repo and the plugin needs only ONE runtime file. Keep things split:

- **In dotfiles (committed):** `sketchybar-app-font/dist/icon_map.json` (plugin reads this path only).
- **System-wide (brew cask `font-sketchybar-app-font`):** `~/Library/Fonts/sketchybar-app-font.ttf`.
- **Source clone (NOT committed):** `~/src/sketchybar-app-font` — `svgs/` + `mappings/` + build tooling.

Add/edit an icon:
```bash
cd ~/src/sketchybar-app-font
# put svg in svgs/:name:.svg, app name in mappings/:name:   (e.g. "Webex")
pnpm install && pnpm run build          # regenerates dist/ from source
# copy the built artifacts into dotfiles + fonts:
cp dist/icon_map.json ~/.dotfiles/sketchybar/sketchybar-app-font/dist/icon_map.json
cp dist/sketchybar-app-font.ttf ~/Library/Fonts/sketchybar-app-font.ttf
```
App name must match AeroSpace's process name.

## Bar appearance

Ported from omerxx/dotfiles: a VERTICAL bar on the right edge.
`height=50 (bar thickness), color=0xcc24273a (translucent), shadow=on, position=right,
topmost=on, sticky=on, padding=18, corner_radius=9, y_offset=10, margin=10, blur_radius=20`

- `position=right` only takes effect when set in sketchybarrc at load time: a live
  `sketchybar --bar position=right` on a running bar is silently ignored, and
  `--query bar` still reports `"position": "top"` while the bar renders vertically.
- The bar is horizontal at the bottom; `left`/`right` items stack left-to-right.
- `topmost=on` was added on top of the reference config so windows never draw over it.
- Window clearance is **AeroSpace gaps**, not sketchybar: `outer.right = 70` (bar thickness
  50 + margin 10 + breathing room), everything else back to small values — windows fill
  the rest of the display.

## Bar items

The bar renders one pill per AeroSpace workspace, all built by
`plugins/aerospacer.sh` (`space.<id>` items: icon = number, label = app glyphs,
click switches workspace, highlight follows `$FOCUSED_WORKSPACE`). Other files:
`colors.sh` (palette), `manage_icons.sh` (manual icon-map utility), and
`sketchybar-app-font/dist/icon_map.json` (app-glyph lookups).

Highlight wiring: `.aerospace.toml exec-on-workspace-change` fires
`sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=... PREV_WORKSPACE=...`;
sketchybar hands KEY=VALUE trigger args to the subscribed script as ENVIRONMENT variables
(not positional), and `aerospacer.sh` compares `$1` (the id baked into the item's `script=`
string) against `$FOCUSED_WORKSPACE`. Pattern for new items:
`sketchybar --add item <name> left --set <name> icon=... label=... update_freq=N script="$PLUGIN_DIR/x.sh"`

## Fonts (what is actually used)

- **SF Pro** (system) — bar text + SF Symbol icons (constants in `colors.sh`)
- **sketchybar-app-font** — `aerospacer.sh` sets `label.font="sketchybar-app-font:Regular:9.0"`; brand-glyph ligatures (`:microsoft_outlook:`) available via `manage_icons.sh`

## Notifications via `lsappinfo`

Reads the Dock badge, no permissions. `lsappinfo info -only StatusLabel "Microsoft Outlook"` ->
`[ NULL ]` (none) or `{ "label"="5" }` (count) or `{ "label"="•" }` (dot). Icon red + count when
unread. **Only sees running apps** (quit app = no badge; accepted, no fallback). Items use
`updates=on` (global default `when_shown` stops polling hidden items). Webex has no brand glyph
-> SF Symbol chat bubble (`WEBEX=􀌨`).

## Borders (JankyBorders) — focused-window border

`FelixKratz/formulae/borders` draws a border around the focused window so you can
see what's active under AeroSpace. No accessibility permission needed (uses private APIs).

- Config: `~/.config/borders/bordersrc` (symlinked from `borders/bordersrc`) — a bash
  script that calls `borders` with options (style, width, hidpi, active_color, inactive_color).
- Colors match the sketchybar palette: active `0xffcad3f5` (white), inactive `0xff494d64`.
- Start: `brew services start borders`. Reconfigure live by running `borders <opts>` again.
- Add to AeroSpace instead (optional): `after-startup-command = ['exec-and-forget borders ...']`.

## Gotchas (each cost real debugging time)

1. **Bash 5.3.9 multibyte bug**: `"$TEMP°"` (unbraced var + multibyte char) -> lone `0xb0` byte ->
   sketchybar renders literal `Warning: Malformed UTF-8 string`. Always brace: `"${TEMP}°"`.
2. **2.24.0 rendering rework**: item `x_offset` REMOVED (use `background.x_offset`);
   `background.width` not a property; `--add group` -> `--add bracket`; popup children flow
   linearly (no true multi-row grid).
3. **`updates=when_shown`** (default) stops polling hidden items -> `updates=on` for hiding items.
4. **Logs**: `/opt/homebrew/var/log/sketchybar/{sketchybar.err.log,sketchybar.out.log}`.
   `sh: /x.sh: No such file` = `$PLUGIN_DIR` empty when item created (source line missing / script
   run outside sketchybarrc).
5. **Debug**: `sketchybar --query item <name>` (JSON nests under `"scripting"`); must be valid
   UTF-8 or the item holds a malformed value.
6. **Concurrent-edit hazard**: other sessions edit these files — verify LIVE state (`--query`),
   disk != loaded sometimes.
7. **`--bar position=right`**: honored only at config load. A live `--bar position=right` on a
   running bar is silently ignored, and `--query bar` keeps reporting `"position": "top"` while
   the bar renders vertically — don't trust the query for bar orientation.
8. **Trigger payload = env vars**: `sketchybar --trigger evt KEY=VAL` reaches the subscribed
   script as `$KEY` in the ENVIRONMENT, not as `$1`. Positional args are only what the item's
   `script=` string bakes in.
9. **`label.drawing=off` also kills `label.background`**: if a pill hides its label,
   its background won't render either, so the focus highlight comes from `icon.highlight`
   + item `background.drawing` (see `plugins/aerospacer.sh`).

## Clone pattern (popup items)

```bash
sketchybar --add item popup.template popup.parent --set popup.template drawing=off ...
# per instance (in plugin):
args+=(--clone popup.item.$N popup.template --set popup.item.$N position=popup.parent drawing=on icon=... label=...)
sketchybar "${args[@]}" >/dev/null
sketchybar --remove '/popup\.item\.*/'    # cleanup old clones
```



# Note for human for karabiner, need to set up extension here
 - System Settings → Privacy & Security — look for a message near the bottom saying something like
   "System software from developer 'Karabiner' was blocked from loading" with an Allow button.
   Click it, then restart Karabiner.
 - You may be prompted to restart your Mac; do it and Karabiner will finish activating.
![](/Users/danielbaker/.dotfiles/doc/karabinerinstall.png)
