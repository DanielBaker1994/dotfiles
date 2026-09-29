#!/usr/bin/env bash

# ---------------------------------------------------------------------------
# Dotfiles deployment for this Mac.
# Symlinks every managed config into place, installs font/tooling deps, and
# applies the macOS system tweaks the setup depends on.
#
# NOTE: the window-manager + status-bar stack (aerospace, sketchybar, borders,
# karabiner, workspace switcher) moved out to the standalone app repo:
#   ~/workspace-switcher/setup.sh   (one command, does its own install)
#
# Safe to re-run: existing symlinks are replaced, real files are backed up to
# /tmp/backup_configs_<timestamp>. Does not uninstall anything.
#
# Requires: brew, sudo (for the ghostty bin symlink).
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

BACKUP_PREFIX="${BACKUP_PREFIX:-/tmp/backup_configs}"
. "$SCRIPT_DIR/symlinks.sh"

case "${1:-}" in
    validate|--validate|check)
        case "${2:-}" in
            --check|check) validate_sym_links check ;;
            --fix|fix)     validate_sym_links fix ;;
            *)             validate_sym_links prompt ;;
        esac
        exit $?
        ;;
    --fix|fix)
        validate_sym_links fix
        exit $?
        ;;
    ""|--install|install)
        ;;
    *)
        printf 'Usage: %s [validate [--check|--fix]]\n' "$0" >&2
        exit 2
        ;;
esac

# Ghostty CLI on PATH (idempotent; -f ignores "already exists")
sudo ln -sf /Applications/Ghostty.app/Contents/MacOS/ghostty /usr/local/bin/ghostty

ensure_sym_links

# ---------------------------------------------------------------------------
# Tooling / dependencies
# ---------------------------------------------------------------------------
echo
echo "==> Ensuring homebrew packages are installed..."

# Icon fonts
#   font-sketchybar-app-font -> app-icon glyphs for the bar (used by
#       ~/workspace-switcher/config/sketchybar/sketchybar-app-font/dist/icon_map.json)
#   font-hack-nerd-font      -> terminal/tmux
brew install --cask font-sketchybar-app-font
brew install --cask font-hack-nerd-font

# Rosetta 2 (Apple silicon): lets Intel-only apps run (oahd is its daemon).
if [[ "$(uname -m)" == "arm64" ]] && ! pgrep -q oahd; then
    sudo softwareupdate --install-rosetta --agree-to-license
fi

# herdr plugins: link every plugin under herdr/plugins (last, agent-tabs, copy-path).
# The link lives in herdr's own state (~/.config/herdr/plugins.json), not a
# symlink; re-linking an already linked plugin is harmless.
if command -v herdr >/dev/null; then
    echo
    echo "==> Linking herdr plugins..."
    for plugin in "$SCRIPT_DIR"/herdr/plugins/*/; do
        herdr plugin link "${plugin%/}" >/dev/null && echo "Linked herdr plugin: ${plugin%/}"
    done
    herdr server reload-config >/dev/null || true
fi

# ---------------------------------------------------------------------------
# System tweaks (idempotent)
# ---------------------------------------------------------------------------
echo
echo "==> Applying macOS system tweaks..."

# Auto-hide the native menu bar so SketchyBar (position=top) takes its place.
# macOS 26+: System Settings > Control Center > "Automatically hide and show the
# menu bar" = Always. The legacy _HIHideMenuBar key alone is NOT enough — the
# newer controlcenter AutoHideMenuBarOption (0=Always … 3=Never) overrides it.
defaults write NSGlobalDomain _HIHideMenuBar -bool true
defaults write com.apple.controlcenter AutoHideMenuBarOption -int 0
osascript -e 'tell application "System Events" to set autohide menu bar of dock preferences to true'
killall ControlCenter Finder 2>/dev/null || true

# "Displays have separate Spaces" off (spans-displays = 1): makes every monitor
# share one set of workspaces. AeroSpace recommends this for stable focus and to
# avoid per-display workspace weirdness (e.g. the Raycast launcher shuffle).
# Requires logout/login to take effect.
defaults write com.apple.spaces spans-displays -bool true

echo
echo "Done. Backups (if any) are under: $BACKUP_PREFIX-*"