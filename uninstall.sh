#!/usr/bin/env bash
set -euo pipefail

MANIFEST_DIR="$HOME/.roon-cava-display"
MANIFEST_FILE="$MANIFEST_DIR/manifest.json"

log(){ echo -e "[uninstall] $*"; }

ensure_sudo(){
  if ! sudo -n true 2>/dev/null; then
    log "Need sudo to revert /etc changes."
    sudo true
  fi
}

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "No manifest found at $MANIFEST_FILE"
  echo "Nothing to uninstall (or install was done by hand)."
  exit 0
fi

BACKUP_DIR="$(python3 -c 'import json;print(json.load(open("'"$MANIFEST_FILE"'"))["backup_dir"])')"

restore(){
  local f="$1"
  local rel="${f#/}"
  local b="$BACKUP_DIR/$rel"
  if [[ -e "$b" || -L "$b" ]]; then
    log "Restoring $f"
    mkdir -p "$(dirname "$f")"
    rm -f "$f"
    if [[ -L "$b" ]]; then
      ln -s "$(readlink "$b")" "$f"
    else
      cp -a "$b" "$f"
    fi
    return 0
  fi
  return 1
}

remove_if_managed(){
  local f="$1"
  if [[ -e "$f" || -L "$f" ]]; then
    log "Removing $f"
    rm -rf "$f"
  fi
}

log "Reverting changes using backup dir: $BACKUP_DIR"

# Restore backed up files if present; otherwise remove created files
restore "$HOME/.asoundrc" || remove_if_managed "$HOME/.asoundrc"
restore "$HOME/.xinitrc" || remove_if_managed "$HOME/.xinitrc"
restore "$HOME/.bash_profile" || true
restore "$HOME/.config/cava/config" || remove_if_managed "$HOME/.config/cava/config"

# Remove our config dir
remove_if_managed "$HOME/.config/roon-cava-display"

# Remove snd-aloop persistent load file if we created it
ensure_sudo
ETC_FILE="/etc/modules-load.d/roon-cava-display-snd-aloop.conf"
if [[ -f "$ETC_FILE" ]]; then
  log "Removing $ETC_FILE"
  sudo rm -f "$ETC_FILE"
fi

# Try to unload module (not fatal if busy)
sudo modprobe -r snd_aloop 2>/dev/null || true

# Optionally keep RoonBridge installed (we do NOT uninstall it by default).
# Users can remove /opt/RoonBridge manually if desired.
log "Note: RoonBridge is not removed automatically."

# Remove manifest
rm -f "$MANIFEST_FILE"
rmdir "$MANIFEST_DIR" 2>/dev/null || true

log "Done. You may want to reboot: sudo reboot"
