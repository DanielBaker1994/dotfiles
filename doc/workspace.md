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
# installed by ~/workspace-switcher/setup.sh (configs copied to ~/.config)
ln -s ~/workspace-switcher/config/aerospace/aerospace.toml ~/.config/aerospace/aerospace.toml

# hide native menu bar
defaults write NSGlobalDomain _HIHideMenuBar -bool true && killall Finder
# (macOS 26 GUI equiv: Settings > Control Center > "Automatically hide and show the menu bar")

brew services start sketchybar      # reload after edits: brew services restart sketchybar
```

## Workspace switcher (native AppKit popup)

`aerospace/workspace_switcher.swift` + `aerospace/PopupWindow.swift` (framework)
+ `aerospace/main.swift`, compiled by `aerospace/workspace_switcher.sh` into
`aerospace/workspace-switcher.app/Contents/MacOS/workspace-switcher` (an app
bundle — rebuilt automatically when a source is newer).
Bound via karabiner (`karabiner/karabiner.json` -> `workspace_switcher.sh`,
which pings the running daemon over a Unix socket or launches it):
- Hyper+S -> workspace switcher popup
- Hyper+J -> jira (jira list window), Hyper+N -> notes window
- menu-bar glyphs toggle jira / notes too: the blue Jira mark
  (`aerospace/jira_icon.png`) and a colorful drawn notepad (drop
  `aerospace/notes_icon.png` next to the binary to override it); both also
  appear in the Hyper+S picker rows and each window's header
- Hyper+S then `/health-checks` -> read-only window running `jira-doctor.sh`
  (commands.conf `type = output`); its header carries `poll all/KAN/SAM1…`
  buttons that force a poll for just that json
- `commands.conf` defines the note/list windows (paths, sources, fields,
  copy-fields); `jira/jira-doctor.sh` asserts the whole stack is wired
- **Build + launch (ONE command)**: `~/workspace-switcher/build.sh` — always rebuilds
  from source, re-signs the .app bundle, re-grants mic/speech, kills stale
  daemons and opens the notes+voice window. No options, no steps.
- **Launching (the only supported way)**: every entry point is
  `workspace_switcher.sh [show|notes|jira|voice]` (in `~/workspace-switcher/bin/`) — the Karabiner shortcuts
  (Hyper+S/J/N), the palette entries, and the menu-bar glyphs all go through
  it. The script rebuilds if a source is newer (killing any stale daemon
  first), re-grants mic/speech, then pings the daemon socket; if no daemon is
  listening it launches the **.app bundle** binary detached
  (`nohup … workspace-switcher.app/Contents/MacOS/workspace-switcher …`).
  NEVER run the sources as a bare `swiftc -o workspace-switcher` binary: its
  ad-hoc signature changes every rebuild, TCC grants reset, and the next
  record press SIGABRTs the process (`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`)
- **One daemon = one menu-bar icon**: the consolidated menu-bar glyph is a
  wrench (`wrench.and.screwdriver`). If you see a SECOND/DIFFERENT icon up
  there, a stale daemon from an old build is still running — kill everything
  with `pkill -f workspace-switcher` and relaunch once
- the launcher runs the .app bundle binary directly (never a shell child or
  LaunchServices): TCC attributes mic/speech-recognition to the app BUNDLE
  (bundle id `dev.danielbaker.workspace-switcher`), so voice works on a cold
  start. `~/workspace-switcher/bin/voice-permissions.sh` re-grants mic + speech after
  every rebuild for BOTH the bundle id AND the .app binary's path (NULL csreq
  = matches any signature, so grants survive every re-sign)
- jeera is a fixed-height window with native trackpad/wheel scrolling; rows
  keep their natural height (no stretch gaps), keyboard jumps glide, and
  on-disk json reloads keep the scroll position. Filter selections truncate
  inside their segment instead of resizing the window mid-pick
- windows float via the `app-name = workspace-switcher` rule in aerospace.toml
- the retired Python/Tk switcher (`workspace_switcher.py`, pillow) is gone

## Voice notes (record -> Apple speech recognition)

Notes and voice are ONE window: `commands.conf [notes]` has `voice = true`
(a note window plus the record/pause/stop meter strip at the bottom — every
note tab, markdown images, and paste work exactly as in plain notes).
Launching `workspace_switcher.sh notes` or `voice` opens/focuses the same
window. The record button starts the mic (live meter strip at the bottom of
the window: pulsing dot + level bars + elapsed), **pause/resume** interrupt
the take, **stop** transcribes it with Apple's SFSpeechRecognizer and APPENDS
the text to the ACTIVE tab — voice commits are
append-only against the file on disk, so a session can never clear earlier
entries, and no dated header block is inserted. The live draft is edited by
range (never by rewriting the note) and is persisted to disk every 1.5s while
recording, so long dictations survive crashes and recognizer hiccups.
Commits happen at NATURAL PAUSES (the on-device recognizer's own silence
detection, ~2s of quiet — the same behavior as Apple's built-in Dictate) and
on stop; a batch that finalizes mid-dictation is immediately restarted so
nothing you say is ever dropped, and text is never finalized mid-word.

- Open with `workspace_switcher.sh voice` (or `/voice` in the palette).
- First record press prompts for microphone + speech recognition permission
  (granted for the binary via the embedded Info.plist — `-sectcreate
  __TEXT __info_plist`). Rebuilds are handled automatically: every rebuild
  re-grants mic + speech via `aerospace/jira/voice-permissions.sh` (path-based
  TCC grants that persist). To force a grant manually:
  `aerospace/jira/voice-permissions.sh` (no sudo — sudo writes to root's db).
- **On-device (offline) dictation requires "Siri & Dictation" enabled** —
  without it, voice notes transcribe over the network only:
  ```bash
  defaults write com.apple.speech.recognition.AppleSpeechRecognition.prefs DictationEnabled -bool true
  ```
  (GUI equiv: System Settings → Apple Intelligence & Siri → Siri & Dictation.
  `/health-checks` reports this state.)
- Dictation locale: `voice-locale` in the `[app]` section of commands.conf.

## Note images (paste a photo, see it inline)

Note windows render markdown images: `![alt](assets/x.png)` shows the picture
inline **fitted to the editor width** (proportions kept — an oversized
screenshot is scaled down so the full image is always visible, like Apple
Notes; smaller images keep their natural size). Pasting a photo from the
clipboard (or dropping an image file onto the note) saves it as
`<note dir>/assets/img-<epoch>.png` (full resolution) and inserts the link at
the caret — no RTF, no manual export. Right-click a rendered photo →
"copy image path" puts its ABSOLUTE path on the clipboard. Saves serialize
attachments back to `![](rel)` so the note stays plain markdown on disk.
Duplicate note paths in commands.conf (`paths = ~/notes, ~/notes/x.md`) are
deduped to one tab.

## Karabiner (Hyper key + switcher binding)

`brew install --cask karabiner-elements`, then symlink + activate the extension:
- import `~/workspace-switcher/config/karabiner/karabiner.json`
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

## Config layout (installed by `~/workspace-switcher/setup.sh` into `~/.config/sketchybar`)

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
cp dist/icon_map.json ~/.config/sketchybar/sketchybar-app-font/dist/icon_map.json
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
