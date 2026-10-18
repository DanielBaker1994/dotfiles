# herdr-pick

The herdr `prefix+w` picker, ported from `connect-herdr.sh` +
`herdr-picker.mjs` into one prebuilt Rust binary.

- **Binary:** `sesh/bin/herdr-pick` (build: `sesh/build-herdr-pick.sh`, run
  automatically by `workspace_setup.sh`)
- **Entry point:** `sesh/connect-herdr.sh` — a launcher that `exec`s the binary
  (`HERDR_PICK_BIN` overrides the path). herdr's config binds prefix+w to it.
  If the binary is missing it builds it once; when it can't (no cargo, broken
  build) it draws an error box instead of going dead.
- **Config:** `sesh/herdr-pick.json` — *everything* the picker runs, says and
  draws: command argv templates, prompts, hints, table headers, row templates,
  help text, keymaps, sizes, timings, status glyphs, palette + style tokens.
  The code contains no commands or user-facing strings.
- **No fallback:** the old node picker (`herdr-picker.mjs`) and fzf backend
  (`connect-herdr-fzf.sh`) are gone; the Rust binary is the picker.

## Build

    sesh/build-herdr-pick.sh

Offline-first (`cargo build --release --offline`, committed `Cargo.lock`,
deps cached), online retry. Output is copied to `sesh/bin/herdr-pick`
(gitignored).

## What it does (parity with the old picker)

- Modes: spaces (`^s`), all (`^a`), agents (`^t`), dirs (`^x`).
- Fuzzy query with highlight; expand/collapse tabs + splits (`^m`/`^e`);
  sort recent/name/status (`^r`). "recent" pins the most previously accessed
  session at the very top (tmux last-session style), current ("here") second.
- Preview pane (live `herdr pane read` / `sesh preview`), border labels.
- **Multi-tab preview grid**: a space with several tabs previews one pane per
  tab in a `ceil(sqrt(k))` grid (capped by `ui.preview_grid.max`, default 4,
  shown as `name · N tabs (M shown)` in the border), each cell headed by the
  tab's status icon, number and name. Single-tab spaces keep the normal
  single-pane preview. Set `ui.preview_grid.enabled = false` to always show
  one pane.
- Mouse: click, double-click, wheel, drag a split (⠿) or a whole tab onto a
  workspace (new tab) or a tab (split), with marching-ants drop frame, landing
  preview, edge auto-scroll, result flash, and `^z` undo (single split).
- Keyboard move (`^g`), kill (`^d`), scratch (`^o`), browser (`^b`), help (`?`).
- CLI grammar kept: `list [MODE] | state | preview LINE | label LINE | kill LINE
  | go LINE|PATH | browser | help` — the node TUI still works against it.
- `HERDR_PICKER_DRY_RUN=1` logs the herdr move command instead of running it.

## Style

The default view follows the kitchen-sink design language (`DESIGN.md`):
the cursor row is a highlight pill with the accent edge (`▌`), status hues
mark agent state, meta is dim, the border label and selection use the accent.
The palette tracks the live kitchen-sink theme: `style.palette_source` reads
the `[theme]` section of `~/.config/kitchen-sink/commands.toml` and derives
the tonal steps (crust/mantle/surface/outline) from it, falling back to the
values in `style.palette`.

## Preview latency

The preview is built to feel instant. How, and the knobs (`behavior`):

- **No idle sleep.** The event loop polls with a short timeout while a list
  or preview fetch is in flight (`poll_active_ms`, default 15 ms), so a
  finished worker is drawn immediately instead of waiting up to
  `poll_idle_ms` (200 ms) for the next tick.
- **Short debounce.** Selection changes wait `preview_debounce_ms` (15 ms)
  before fetching, so holding ↓ doesn't spawn a command per row.
- **Prefetch.** ~`preview_prefetch_delay_ms` (120 ms) after the cursor
  settles, the rows `±preview_prefetch` around it are fetched in the
  background and cached, so the next ↑/↓ is served from cache.
- **Stale-while-revalidate.** Any cached text is drawn the moment the row is
  selected, even past `preview_cache_ms` (3 s); a fresh copy then replaces it
  in the background (scroll position is kept on refresh).
- **Stable cache keys.** Previews are keyed by kind + target (e.g.
  `pane wB:p10`), so they survive list reloads and display changes.
- **One process per fetch.** Preview commands run directly
  (`herdr pane read …`, `sesh preview …`), never through a shell.

Measured: `herdr pane read` ~5 ms, `sesh preview` ~10–20 ms, so a cold row
costs ~20–40 ms end to end; a prefetched row is immediate.

