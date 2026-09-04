---
name: swift
description: Use when working with Swift/AppKit code in this repo — building or debugging the workspace-switcher daemon (workspace_switcher.swift, PopupWindow.swift, main.swift), rebuilding after edits, killing/relaunching the daemon, mic/speech permission issues, or anything about the voice/jira/notes windows. Also for Swift proficiency tips.
---

# Swift & workspace-switcher dev workflow

The workspace switcher is a bare-binary AppKit app compiled with `swiftc`
(framework `PopupWindow.swift` + host `workspace_switcher.swift` + entry
`main.swift`). No Xcode project, no SPM — the binary IS the app.

## Build + launch (ONE command)

`./build.sh` (in `~/workspace-switcher/`, the standalone app repo) — always rebuilds from source, re-signs
the .app bundle, re-grants mic/speech, kills stale daemons, and opens the
notes+voice window. No options, no other steps. Use it for everything.

For fast iteration WITHOUT a rebuild (config-only edits, quick relaunch):
```bash
pkill -f workspace-switcher; ~/workspace-switcher/bin/workspace_switcher.sh notes
```

## Manual rebuild loop (only when build.sh is unavailable)

1. Kill the running daemon:
   ```bash
   pkill -f workspace-switcher
   ```
2. Build — the embedded-Info.plist flags are MANDATORY (mic + speech
   permissions read them via TCC). Build straight into the .app bundle — a
   bare binary in the repo dir is a TCC trap: its ad-hoc signature changes on
   every rebuild, so grants reset and the NEXT voice session SIGABRTs
   (`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__`, seen in ~/.cache/ws-crash.log).
   ```bash
   swiftc -O -swift-version 5 \
     -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist \
     PopupWindow.swift workspace_switcher.swift main.swift \
     -o workspace-switcher.app/Contents/MacOS/workspace-switcher
   codesign --force --sign - --identifier dev.danielbaker.workspace-switcher workspace-switcher.app
   ```
   (Never write a raw `workspace-switcher` binary next to the sources.)
3. Re-grant mic + speech AFTER EVERY manual build: the re-sign changes the
   binary's cdhash, and macOS flips the speech/mic status back to
   "not determined" until `jira/voice-permissions.sh` re-inserts the grants
   (it now writes the .app PATH with NULL csreq, which matches any signature):
   ```bash
   jira/voice-permissions.sh
   ```
4. Launch a window detached (the `( … & )` subshell detaches from the tool's
   process group so the shell doesn't hang; capture stderr = the `ws:` log).
   ALWAYS launch the .app bundle binary — the grants (bundle id + path)
   survive rebuilds:
   ```bash
   ( ./workspace-switcher.app/Contents/MacOS/workspace-switcher notes >/tmp/ws-voice.log 2>&1 & )
   ```
   Modes: `show` (switcher popup), `notes`, `jira`, `voice` (aliases to the
   merged notes+voice window), `toggle`.
5. Iterate: check `/tmp/ws-voice.log` for `ws: ...` log lines after actions.

Fast type-check without linking (seconds, no binary):
```bash
swiftc -typecheck PopupWindow.swift workspace_switcher.swift main.swift
```

`workspace_switcher.sh` auto-rebuilds when sources are newer, and
`jira/jira-doctor.sh --fix` rebuilds too — but always preserve the sectcreate
flags in any manual build.

## TCC permissions (the #1 footgun)

- Mic + speech work ONLY because Info.plist is embedded via
  `-Xlinker -sectcreate … __info_plist`. Drop those flags and voice notes die
  silently.
- TCC grants are per-binary-signature; every rebuild re-signs ad-hoc, so
  grants can reset. If recording does nothing: check the daemon log for the
  permission error and tell the user to re-add the binary in System Settings >
  Privacy & Security > Microphone + Speech Recognition.
- NEVER block the main thread on a TCC prompt (`AVCaptureDevice.requestAccess`
  completion may never fire for ad-hoc binaries → the app freezes). Kick
  requests off async and let the user press record again.
- On-device dictation needs "Siri & Dictation" enabled:
  `defaults write com.apple.speech.recognition.AppleSpeechRecognition.prefs DictationEnabled -bool true`
  (doctor reports this state).

## Testing UI without a mouse

- Synthetic clicks DO reach the UI if the poster is AX-trusted
  (`AXIsProcessTrusted()`); verify by logging in the handler, not by eyeballing.
- Find the window frame with `CGWindowListCopyWindowInfo` (bounds are
  top-left origin), then post `CGEvent` mouseDown/Up at button coordinates.
- Instrument with temporary `log()`/stderr prints at handler entry points;
  remove them before finishing.

## AppKit patterns used here (match them)

- **Hooks, not delegation**: everything is a closure — `onDrawRow`, `onFilter`,
  `onAccept`, `onHeaderButton`. New window behavior = new hook, never a
  subclass.
- **Flipped coordinates**: views with `isFlipped = true` have y=0 at the TOP;
  `hitTest`/`mouseDown`/`draw(_:)` all receive flipped points. Keep rect math
  in one space.
- **Chrome overlay**: `PopupChrome` is a full-window overlay view on top of the
  content; it claims click zones by returning `self` from `hitTest`, then
  dispatches in `mouseDown`. The record bar and drag header work this way.
- **Custom drawing**: `draw(_:)` + `NSBezierPath`, no layers for the chrome.
  Always `needsDisplay = true` after state changes (e.g. the live meter ticks).
- **Editor**: edit-mode windows use an `NSTextView` inside a scroll view;
  `setEditorText` replaces plain text, `setEditorAttributedText` keeps rich
  text (ANSI-rendered doctor output uses it).
- **Retain cycles**: closures capturing views strongly create leaks — window
  ↔ recorder was one. Host closures use `[weak self, weak w]`; local funcs
  that need the window should take it as a parameter.
- **Polling**: `Timer` on `RunLoop.main` (`.common` mode) for file watchers;
  timeouts via `DispatchSemaphore` with `.now() + n` on background queues.

## Architecture map

- `PopupWindow.swift` — reusable framework: window/panel, chrome/header,
  rows, search/filter, editor, meter bar, socket toggle server.
- `workspace_switcher.swift` — host: commands.conf parsing (`[app]`,
  `[icons]`, per-command sections), aerospace IPC, icons, voice recorder
  (AVAudioRecorder + SFSpeechRecognizer), AppDelegate.
- `main.swift` — entry: `applyAppConfigFromDisk()` FIRST (socket names come
  from config), then arg dispatch (`toggle`/`notes`/`jira`/`voice`).
- `commands.conf` — every machine string + window definition lives here
  (`[app]` section). Config-driven is the goal: new windows need no code.

## Swift/AppKit effectiveness

- Type-check fast (`-typecheck`), link rarely; fix one error class at a time.
- Keep `var`/`let` explicit about laziness: file-scope `let` initializes on
  FIRST ACCESS — the config-parsing order matters (that's why
  `applyAppConfigFromDisk()` runs first in main.swift).
- Prefer `String`/`NSString` carefully: drawing APIs take `NSString`;
  `split(separator:)` is Swift-native.
- When a UI thing "does nothing", log the state machine transitions — the
  record button "dead" bug was a frozen main thread + a silent permission
  failure, not a missing handler.
- Learn `NSBezierPath`, `NSRect` math, and `isFlipped` — 90% of custom AppKit
  UI is drawing + hit-testing, both trivial once flipped coords are second
  nature.