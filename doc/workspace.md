# Daniel Workspace Documents
Setting up workspace and suggested commands.

```bash
# For neovim easier now to ~/cd to workspace
cd ~
ln -s ~/src/cpp_workspace ~/cpp
ln -s ~/src/java_workspace ~/java
ln -s ~/src/root_workspace ~/root
```



```vim
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






> [!NOTE]
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



> [!NOTE]
> iTerm2 window can be hidden like Kitty.

![](/Users/danielbaker/.dotfiles/doc/hiding_menu_bar.png)

---

# AeroSpace + Kitchen Sink

SketchyBar was removed on 2026-10-06. Its workspace map (which apps are on
which workspace), unread chips and CPU / RAM / battery / clock now live in the
Hyper+S switcher (one view: workspace rows, a command grid, a status row). The
native macOS menu bar is visible again.
Deploy with `./workspace_setup.sh` (symlinks everything, installs deps).

## Install / bootstrap

```bash
# symlinks (workspace_setup.sh does these)
# installed by ~/.config/kitchen-sink/setup.sh (configs copied to ~/.config)
ln -s ~/.config/kitchen-sink/config/aerospace/aerospace.toml ~/.config/aerospace/aerospace.toml

# disable cmd+M minimize globally (maps Minimize menu item to nothing)
defaults write -g NSUserKeyEquivalents -dict-add 'Minimize' '\0'

```

## Kitchen sink (native AppKit popup)

`aerospace/kitchen_sink.swift` + `aerospace/PopupWindow.swift` (framework)
+ `aerospace/main.swift`, compiled by `aerospace/kitchen_sink.sh` into
`aerospace/kitchen-sink.app/Contents/MacOS/kitchen-sink` (an app
bundle — rebuilt automatically when a source is newer).
Bound via karabiner (`karabiner/karabiner.json` -> `kitchen_sink.sh`,
which pings the running daemon over a Unix socket or launches it):
- Hyper+S -> kitchen sink popup
- Hyper+J -> jira (jira list window), Hyper+N -> notes window
- menu-bar glyphs toggle jira / notes too: the blue Jira mark
  (`aerospace/jira_icon.png`) and a colorful drawn notepad (drop
  `aerospace/notes_icon.png` next to the binary to override it); both also
  appear in the Hyper+S picker rows and each window's header
- Hyper+S then `/health-checks` -> read-only window running `jira-doctor.sh`
  (commands.toml `type = output`); its header carries `poll all/KAN/SAM1…`
  buttons that force a poll for just that json
- `commands.toml` defines the note/list windows (paths, sources, fields,
  copy-fields); `jira/jira-doctor.sh` asserts the whole stack is wired
- **Build + launch (ONE command)**: `~/.config/kitchen-sink/build.sh` — always rebuilds
  from source, re-signs the .app bundle, re-grants mic/speech, kills stale
  daemons and opens the notes+voice window. No options, no steps.
- **Launching (the only supported way)**: every entry point is
  `kitchen_sink.sh [show|notes|jira|voice]` (in `~/.config/kitchen-sink/bin/`) — the Karabiner shortcuts
  (Hyper+S/J/N), the palette entries, and the menu-bar glyphs all go through
  it. The script rebuilds if a source is newer (killing any stale daemon
  first), re-grants mic/speech, then pings the daemon socket; if no daemon is
  listening it launches the **.app bundle** binary detached
  (`nohup … kitchen-sink.app/Contents/MacOS/kitchen-sink …`).
  NEVER run the sources as a bare `swiftc -o kitchen-sink` binary: its
  ad-hoc signature changes every rebuild, TCC grants reset, and the next
  record press SIGABRTs the process (`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`)
- **One daemon = one menu-bar icon**: the consolidated menu-bar glyph is a
  wrench (`wrench.and.screwdriver`). If you see a SECOND/DIFFERENT icon up
  there, a stale daemon from an old build is still running — kill everything
  with `pkill -f kitchen-sink` and relaunch once
- the launcher runs the .app bundle binary directly (never a shell child or
  LaunchServices): TCC attributes mic/speech-recognition to the app BUNDLE
  (bundle id `dev.danielbaker.kitchen-sink`), so voice works on a cold
  start. `~/.config/kitchen-sink/bin/voice-permissions.sh` re-grants mic + speech after
  every rebuild for BOTH the bundle id AND the .app binary's path (NULL csreq
  = matches any signature, so grants survive every re-sign)
- jeera is a fixed-height window with native trackpad/wheel scrolling; rows
  keep their natural height (no stretch gaps), keyboard jumps glide, and
  on-disk json reloads keep the scroll position. Filter selections truncate
  inside their segment instead of resizing the window mid-pick
- windows float via the `app-name = kitchen-sink` rule in aerospace.toml
- the retired Python/Tk switcher (`kitchen_sink.py`, pillow) is gone

## Voice notes (record -> Apple speech recognition)

Notes and voice are ONE window: `commands.toml [notes]` has `voice = true`
(a note window plus the record/pause/stop meter strip at the bottom — every
note tab, markdown images, and paste work exactly as in plain notes).
Launching `kitchen_sink.sh notes` or `voice` opens/focuses the same
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

- Open with `kitchen_sink.sh voice` (or `/voice` in the palette).
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
- Dictation locale: `voice-locale` in the `[app]` section of commands.toml.

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
Duplicate note paths in commands.toml (`paths = ~/notes, ~/notes/x.md`) are
deduped to one tab.

## Karabiner (Hyper key + switcher binding)

`brew install --cask karabiner-elements`, then symlink + activate the extension:
- import `~/.config/kitchen-sink/config/karabiner/karabiner.json`
- caps_lock -> Hyper (Cmd+Ctrl+Opt+Shift); Hyper+S -> `kitchen_sink.sh`
- System Settings → Privacy & Security → allow the blocked Karabiner system software, restart (see bottom of this doc + `doc/karabinerinstall.png`)

## Disabled on purpose

- **Separate Spaces per display**: `defaults write com.apple.spaces spans-displays -bool true`
  (all monitors share one workspace set; AeroSpace recommends this for stable focus —
  requires logout/login to take effect; set in `workspace_setup.sh`).
- **Ghostty**: `mouse-hide-while-typing` and the `custom-shader` soft-trail are commented out
  (`ghostty/config.ghostty`).
- **AeroSpace floating rules**: Flameshot (`org.flameshot`) floats; the Raycast launcher is
  auto-ignored (dialog heuristic, >= 0.18.3) so it needs no rule.

## Borders (JankyBorders) — focused-window border

`FelixKratz/formulae/borders` draws a border around the focused window so you can
see what's active under AeroSpace. No accessibility permission needed (uses private APIs).

- Config: `~/.config/borders/bordersrc` (symlinked from `borders/bordersrc`) — a bash
  script that calls `borders` with options (style, width, hidpi, active_color, inactive_color).
- Colors: active `0xffcad3f5` (white), inactive `0xff494d64` (Catppuccin Macchiato).
- Start: `brew services start borders`. Reconfigure live by running `borders <opts>` again.
- Add to AeroSpace instead (optional): `after-startup-command = ['exec-and-forget borders ...']`.

# Note for human for karabiner, need to set up extension here
 - System Settings → Privacy & Security — look for a message near the bottom saying something like
   "System software from developer 'Karabiner' was blocked from loading" with an Allow button.
   Click it, then restart Karabiner.
 - You may be prompted to restart your Mac; do it and Karabiner will finish activating.
![](/Users/danielbaker/.dotfiles/doc/karabinerinstall.png)
