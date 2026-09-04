# Voice window: dictation scroll + close/relaunch fixes

## Bug 1 — dictation text out of view, no auto-scroll

**Root cause:** `workspace_switcher.swift:2018` (voice `onPartial`) calls
`scrollEditorToEnd(ifAtBottom: true)`. The guard in
`PopupWindow.swift:2811-2815` only follows when
`docH - visible.maxY < 80` — i.e. the view must already be within 80pt of the
bottom. For a long note, the view stays above the streamed text forever.

**Fix (workspace_switcher.swift):**
- `voice.onPartial`: `w.scrollEditorToEnd(ifAtBottom: true)` → `w.scrollEditorToEnd()`
  (always follow the caret during dictation).
- `voice.onError` (line ~2042): after `w.setEditorText(updated)` add
  `w.scrollEditorToEnd()` so an error message is visible too.

## Bug 2 — close voice window, relaunch, "never works"

### 2a. Wrong window gets focused
`showCommand` (`workspace_switcher.swift:1375-1379`) uses
`focusExistingOrOpen(editMode: true)`, and `existingWindow(editMode:)`
(line 1395) matches the FIRST edit-mode window. Notes, voice and output
windows are all `editMode: true` → with notes open, launching voice focuses
notes and never opens the voice window.

**Fix:** in `showCommand`, match by name:
```swift
case .note:
    let existing = subWindows.first { $0.config.name == cmd.windowName }
    if let existing { focusSubWindow(existing) } else { openNoteWindow(...) }
```
(`toggleCommand` already matches by `config.name` — line 1613 — leave it.)

### 2b. Recorder/AVAudioEngine leak on close (mic held forever)
The window's hook closures capture the window strongly
(`w.onMeterRecord`, `w.onTabChange`, `w.onEditorCommit`, `w.onHide`, …),
so after `hide()` + `unregisterSubWindow` the window object is retained
by its own closures and never deallocs. The `VoiceRecorder` (with the
running `AVAudioEngine`) is captured by those closures → engine keeps the
mic even after the window closes. `onHideVoiceStop → voice.stop()` only
finalizes the recognition batch; the engine stops ONLY if the final
`onBatch` callback lands (`resetSession`). If the task hangs, state sticks
at `.transcribing` with the mic held → the NEXT voice launch's
`engine.start()` fails → "recording failed" → record button dead.

**Fix A — `VoiceRecorder.stop()` (workspace_switcher.swift:1192):**
tear the engine down unconditionally and return to idle immediately:
```swift
func stop() {
    guard state == .recording || state == .paused else { return }
    finalizeBatch()
    ticker?.invalidate(); ticker = nil
    batchTimer?.invalidate(); batchTimer = nil
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    state = .idle
    onStateChange?(state)
}
```
The in-flight final batch still delivers `onBatch` → `commit()` (harmless;
`resetSession` path no longer needed there).

**Fix B — break the retain cycle (PopupWindow.swift `hide()`, ~line 2696):**
after firing `onEditorClose` / `onHideVoiceStop` / `onHide`, nil every
public hook property so the window (and everything its closures captured,
incl. the recorder) can dealloc. Add a private `clearHooks()` and call it at
the end of `hide()`. Hooks to nil (grep `public var on` in PopupWindow.swift:
`onFilter`, `onAccept`, `onEscape`, `onShow`, `onHide`, `onDrawRow`,
`onChromeHeaderClick`, `onChromeConfigClick`, `onHeaderButton`, `onTabClick`,
`onTabChange`, `onAddTab`, `onEditorCommit`, `onEditorClose`,
`onHideVoiceStop`, `onMeterRecord`, `onMeterPause`, `onCopyRowClick`…).

### 2c. TCC SIGABRT on non-bundle launch (proven in crash log)
`~/.cache/ws-crash.log` 2026-09-14 18:53:04: `signal=6`,
`__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__` — a TCC *request* aborted the
process. Classic for the raw (non-.app) binary launched directly
(`./workspace-switcher voice`): path/signature attribution fails → abort.
Grants exist for both the bundle id and the raw path, but the raw binary is
re-signed on every rebuild → grant mismatch → request → SIGABRT.

**Fix (launch hygiene):**
- Delete the stray raw binary `/Users/danielbaker/.dotfiles/aerospace/workspace-switcher`
  (does not exist right now; ensure it never reappears — always launch via
  `workspace_switcher.sh` which uses the .app bundle).
- Future manual test launches: use
  `( ./workspace-switcher.app/Contents/MacOS/workspace-switcher voice >/tmp/ws-voice.log 2>&1 & )`
  (bundle-id grants survive rebuilds).
- Optional user cleanup: remove the stale path-based grant for
  `/Users/danielbaker/.dotfiles/aerospace/workspace-switcher` in System
  Settings > Privacy & Security (Microphone + Speech Recognition).

## Verification
1. `swiftc -typecheck PopupWindow.swift workspace_switcher.swift main.swift`
2. Rebuild + relaunch via `workspace_switcher.sh voice` (script rebuilds).
3. Dictate into a long note → editor follows the streamed text.
4. Close the voice window mid-recording → relaunch voice → record works.
5. Open notes, then launch voice → voice window opens (not notes).
6. Check `/tmp/ws-voice.log` + `~/.cache/ws-crash.log` for errors.