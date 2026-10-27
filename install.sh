#!/bin/bash
# Install Orpheus on an Omarchy machine, from wherever this checkout lives.
#
#   ./install.sh              install, or bring an install up to date (safe to re-run)
#   ./install.sh --check      say what is missing, change nothing
#   ./install.sh --uninstall  undo everything this script did; keeps your
#                             sign-in, likes cache and EQ in ~/.local/state/orpheus
#
# Works from a plain clone or from `omarchy plugin add`, which clones into
# ~/.config/omarchy/plugins/orpheus.
set -euo pipefail

DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
PLUGIN=~/.config/omarchy/plugins/orpheus
UNIT=~/.config/systemd/user/orpheusd.service
HYPR=~/.config/hypr
REQUIRE='require("hypr.orpheus")'

ok()   { printf '  \e[32m✓\e[0m %s\n' "$*"; }
note() { printf '  \e[33m•\e[0m %s\n' "$*"; }
fail() { printf '  \e[31m✗\e[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\e[1m%s\e[0m\n' "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }

# ---- what is there ---------------------------------------------------------

REQUIRED=(mpv cava uv jq)
OPTIONAL=("yt-dlp:YouTube and SoundCloud" "ani-cli:anime search and playback" "curd:anime with AniList sync")

check() {
  step "checking"
  has omarchy-shell || fail "omarchy-shell not found: Orpheus is an Omarchy shell plugin and needs Omarchy (https://omarchy.org)"
  has hyprctl || fail "hyprctl not found: Orpheus needs Hyprland"
  ok "Omarchy and Hyprland"
  missing=()
  for c in "${REQUIRED[@]}"; do has "$c" || missing+=("$c"); done
  if ((${#missing[@]})); then
    note "missing: ${missing[*]}"
    note "install them with: omarchy pkg add ${missing[*]}"
    return 1
  fi
  ok "mpv, cava, uv, jq"
  for o in "${OPTIONAL[@]}"; do
    has "${o%%:*}" && ok "${o%%:*}" || note "${o%%:*} not installed (optional: ${o#*:})"
  done
  return 0
}

# ---- install ---------------------------------------------------------------

install() {
  if ! check; then
    if [[ -t 0 ]]; then
      read -rp "  install the missing packages now? [Y/n] " a
      [[ ${a:-y} =~ ^[Yy] ]] || exit 1
      omarchy pkg add "${missing[@]}"
      check || exit 1
    else
      exit 1
    fi
  fi

  step "plugin"
  if [[ $(readlink -f "$PLUGIN" 2>/dev/null) == "$DIR" ]]; then
    ok "$PLUGIN"
  elif [[ -e $PLUGIN || -L $PLUGIN ]]; then
    fail "$PLUGIN already exists and is not this checkout; remove it or run install.sh from there"
  else
    mkdir -p "${PLUGIN%/*}"; ln -s "$DIR" "$PLUGIN"; ok "linked $PLUGIN -> $DIR"
  fi

  step "daemon"
  (cd "$DIR" && uv sync --frozen --quiet) && ok "python environment (.venv)"
  mkdir -p "${UNIT%/*}"
  # The unit is written, not linked, so it points at this checkout wherever it is.
  rm -f "$UNIT"
  sed "s|^ExecStart=.*|ExecStart=$DIR/.venv/bin/orpheusd|" "$DIR/orpheusd.service" >"$UNIT"
  systemctl --user daemon-reload
  systemctl --user enable --quiet orpheusd.service
  systemctl --user restart orpheusd.service && ok "orpheusd.service running"

  step "launcher"
  mkdir -p ~/.local/bin ~/.local/share/applications
  ln -sfn "$DIR/bin/orpheus" ~/.local/bin/orpheus && ok "~/.local/bin/orpheus"
  cp "$DIR"/share/applications/*.desktop ~/.local/share/applications/ && ok "desktop entries"

  step "hyprland"
  ln -sfn "$DIR/hypr/orpheus.lua" "$HYPR/orpheus.lua"
  if grep -qF "$REQUIRE" "$HYPR/hyprland.lua"; then
    ok "rules and keys already loaded"
  else
    cp "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak.$(date +%s)"
    printf '\n-- Added by Orpheus (install.sh --uninstall removes it)\n%s\n' "$REQUIRE" >>"$HYPR/hyprland.lua"
    ok "window rules and keys (hyprland.lua backed up first)"
  fi
  hyprctl reload >/dev/null
  errs=$(hyprctl configerrors)
  [[ -z ${errs//[[:space:]]/} ]] || note "hyprland reports: $errs"

  step "shell"
  # Plugins are not hot-reloaded, and the bar widget only appears once enabled.
  omarchy-shell -q shell rescanPlugins
  if omarchy plugin list --json | jq -e 'any(.[]; .id == "orpheus" and .enabled)' >/dev/null; then
    ok "plugin enabled"
  else
    omarchy plugin enable orpheus --section right >/dev/null && ok "plugin enabled, widget on the right of the bar"
  fi
  omarchy restart shell >/dev/null 2>&1 && ok "shell restarted"

  step "done"
  echo "  Super+Shift+M opens the player, Super+Ctrl+M the visualizer."
  echo "  Sign in to TIDAL with Ctrl+Shift+O; the video section (8) works without it."
  echo "  Your own keys instead: put orpheus_bindings = false above the require in hyprland.lua."
}

# ---- uninstall -------------------------------------------------------------

uninstall() {
  step "removing"
  omarchy plugin disable orpheus >/dev/null 2>&1 && ok "plugin disabled" || true
  if systemctl --user cat orpheusd.service >/dev/null 2>&1; then
    systemctl --user disable --now --quiet orpheusd.service || true
    rm -f "$UNIT"; systemctl --user daemon-reload; ok "orpheusd.service removed"
  fi
  [[ $(readlink -f ~/.local/bin/orpheus 2>/dev/null) == "$DIR/bin/orpheus" ]] && rm -f ~/.local/bin/orpheus && ok "launcher"
  for f in "$DIR"/share/applications/*.desktop; do rm -f ~/.local/share/applications/"${f##*/}"; done
  if grep -qF "$REQUIRE" "$HYPR/hyprland.lua" 2>/dev/null; then
    cp "$HYPR/hyprland.lua" "$HYPR/hyprland.lua.bak.$(date +%s)"
    grep -vF -e "$REQUIRE" -e "-- Added by Orpheus" "$HYPR/hyprland.lua" >"$HYPR/hyprland.lua.tmp"
    mv "$HYPR/hyprland.lua.tmp" "$HYPR/hyprland.lua"
    hyprctl reload >/dev/null; ok "hyprland rules and keys"
  fi
  [[ -L $HYPR/orpheus.lua ]] && rm -f "$HYPR/orpheus.lua"
  # Only a link is ours to remove; a real folder came from `omarchy plugin add`.
  if [[ -L $PLUGIN ]]; then rm -f "$PLUGIN"; ok "plugin link"
  else note "remove the plugin itself with: omarchy plugin remove orpheus"; fi
  omarchy restart shell >/dev/null 2>&1 || true
  ok "done; ~/.local/state/orpheus is kept (delete it to forget your sign-in)"
}

case "${1:-}" in
  --check) check ;;
  --uninstall) uninstall ;;
  "") install ;;
  *) echo "usage: $0 [--check | --uninstall]"; exit 2 ;;
esac
