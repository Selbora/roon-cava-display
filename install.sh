#!/usr/bin/env bash
set -euo pipefail

# Roon → Pi (RoonBridge) → ALSA tee (HDMI + Loopback) → CAVA fullscreen
# Tested on DietPi / Raspberry Pi OS (Pi Zero 2 W).
#
# Minimal-intervention installer:
#  - Installs deps (roonbridge, cava, xorg minimal, xterm, unclutter, alsa-utils)
#  - Enables snd-aloop persistently
#  - Creates ~/.asoundrc tee: HDMI out + Loopback playback
#  - Creates 2 CAVA configs (mirror neon + VU dual)
#  - Creates ~/.xinitrc that starts CAVA fullscreen + night dim
#  - Adds 'startx' to ~/.bash_profile (only if not already present)
#
# Usage:
#   ./install.sh [--resolution 1600x600] [--mode mirror|vu] [--no-hdmi-audio]
#
# Notes:
#  - If you don't want the Pi to output any sound, use --no-hdmi-audio (uses 'null' sink).
#  - Roon should be configured to play to the Pi endpoint; ensure audio is playing.
#
# Uninstall:
#   ./uninstall.sh

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="$HOME/.roon-cava-display"
MANIFEST_FILE="$MANIFEST_DIR/manifest.json"
BACKUP_ROOT="$HOME/.roon-cava-backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/$STAMP"

RESOLUTION="1600x600"
MODE="mirror"   # mirror | vu
NO_HDMI_AUDIO="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolution)
      RESOLUTION="${2:-}"; shift 2;;
    --mode)
      MODE="${2:-}"; shift 2;;
    --no-hdmi-audio)
      NO_HDMI_AUDIO="1"; shift;;
    -h|--help)
      sed -n '1,120p' "$0"; exit 0;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Try: ./install.sh --help" >&2
      exit 2;;
  esac
done

if [[ "$MODE" != "mirror" && "$MODE" != "vu" ]]; then
  echo "ERROR: --mode must be 'mirror' or 'vu' (got '$MODE')" >&2
  exit 2
fi

mkdir -p "$MANIFEST_DIR" "$BACKUP_DIR"

log(){ echo -e "[install] $*"; }

need_cmd(){ command -v "$1" >/dev/null 2>&1; }

backup_file(){
  local f="$1"
  if [[ -e "$f" || -L "$f" ]]; then
    local rel="${f#/}" # strip leading slash for backup path
    local dest="$BACKUP_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    # Preserve symlinks as symlinks
    if [[ -L "$f" ]]; then
      local target; target="$(readlink "$f")"
      ln -s "$target" "$dest"
    else
      cp -a "$f" "$dest"
    fi
    echo "$f"
  fi
}

ensure_sudo(){
  if ! sudo -n true 2>/dev/null; then
    log "Need sudo for package install + /etc changes."
    sudo true
  fi
}

detect_alsa_cards(){
  # Determine:
  #  - LOOP_CARD: card number for Loopback
  #  - HDMI_CARD + HDMI_DEV: vc4hdmi card+device for playback (if present)
  local aplay_out
  aplay_out="$(aplay -l 2>/dev/null || true)"
  if [[ -z "$aplay_out" ]]; then
    echo "ERROR: 'aplay -l' produced no output. Is alsa-utils installed?" >&2
    exit 1
  fi

  LOOP_CARD="$(echo "$aplay_out" | awk -F'[: ]+' '/card [0-9]+: Loopback/ {print $2; exit}')"
  if [[ -z "${LOOP_CARD:-}" ]]; then
    echo "ERROR: Could not find ALSA Loopback card in 'aplay -l'. Is snd-aloop loaded?" >&2
    exit 1
  fi

  HDMI_CARD="$(echo "$aplay_out" | awk -F'[: ]+' '/card [0-9]+: vc4hdmi/ {print $2; exit}')"
  HDMI_DEV="$(echo "$aplay_out" | awk -F'[: ,]+' '/card [0-9]+: vc4hdmi/ {for(i=1;i<=NF;i++) if($i=="device"){print $(i+1); exit}}')"
  if [[ -z "${HDMI_CARD:-}" || -z "${HDMI_DEV:-}" ]]; then
    HDMI_CARD=""
    HDMI_DEV=""
  fi
}

write_files(){
  log "Writing configs to home directory…"

  mkdir -p "$HOME/.config/cava"
  mkdir -p "$HOME/.config/roon-cava-display"

  # Two CAVA presets
  cat > "$HOME/.config/roon-cava-display/mirror-neon.conf" <<'EOF'
[general]
framerate = 60
autosens = 1
# 1600px wide: (bar_width + bar_spacing) = 8px -> ~200 bars
bars = 200
bar_width = 6
bar_spacing = 2
smoothing = 0
sleep_timer = 0

[input]
method = alsa
# Installer sets the correct loopback capture device here:
source = __CAVA_INPUT_SOURCE__

[output]
method = sdl
sdl_full_screen = 1
# "stereo" here means mirrored spectrum centered in the middle (symmetry)
channels = stereo
reverse = 0

[color]
background = '#000000'
gradient = 1
gradient_color_1 = '#00FFFF'
gradient_color_2 = '#00FF00'
gradient_color_3 = '#FFFF00'
gradient_color_4 = '#FF7A00'
gradient_color_5 = '#FF003C'
gradient_color_6 = '#FF00FF'
gradient_color_7 = '#7A00FF'
gradient_color_8 = '#005BFF'
EOF

  cat > "$HOME/.config/roon-cava-display/vu-dual.conf" <<'EOF'
[general]
framerate = 60
autosens = 1

[input]
method = alsa
source = __CAVA_INPUT_SOURCE__

[output]
# This mode gives a true L/R split (top/bottom) using a terminal renderer.
# It’s less "pretty" than SDL but is the closest native "dual channel" layout.
method = noncurses
orientation = horizontal
channels = stereo
horizontal_stereo = 1
left_bottom = 1

[color]
background = '#000000'
gradient = 1
gradient_color_1 = '#00FF00'
gradient_color_2 = '#00FFFF'
gradient_color_3 = '#FF00FF'
gradient_color_4 = '#FF003C'
EOF

  # Active mode selection
  ln -sf "$HOME/.config/roon-cava-display/mirror-neon.conf" "$HOME/.config/roon-cava-display/active.conf"
  if [[ "$MODE" == "vu" ]]; then
    ln -sf "$HOME/.config/roon-cava-display/vu-dual.conf" "$HOME/.config/roon-cava-display/active.conf"
  fi

  # CAVA input source from loopback capture (device 1, subdevice 0)
  local cava_source="hw:${LOOP_CARD},1,0"

  # Patch placeholders
  sed -i "s#__CAVA_INPUT_SOURCE__#${cava_source}#g" \
    "$HOME/.config/roon-cava-display/mirror-neon.conf" \
    "$HOME/.config/roon-cava-display/vu-dual.conf"

  # Convenience symlink: ~/.config/cava/config -> active.conf
  backup_file "$HOME/.config/cava/config" >/dev/null || true
  ln -sf "$HOME/.config/roon-cava-display/active.conf" "$HOME/.config/cava/config"

  # Display environment (editable by user)
  cat > "$HOME/.config/roon-cava-display/display.env" <<EOF
# Screen resolution; used by xrandr --mode (if supported by your panel)
RESOLUTION="${RESOLUTION}"

# Night dim schedule (24h)
NIGHT_START="22"
NIGHT_END="7"

# Brightness values for xrandr --brightness
DAY_BRIGHTNESS="1.00"
NIGHT_BRIGHTNESS="0.20"
EOF

  # X init (auto dim + start CAVA)
  backup_file "$HOME/.xinitrc" >/dev/null || true
  cat > "$HOME/.xinitrc" <<'EOF'
#!/bin/sh
set -eu

# Load display env if present
ENV="$HOME/.config/roon-cava-display/display.env"
if [ -f "$ENV" ]; then
  # shellcheck disable=SC1090
  . "$ENV"
fi

xset -dpms
xset s off
xset s noblank

# Hide cursor
command -v unclutter >/dev/null 2>&1 && unclutter -idle 0.1 -root &

# Detect connected output (HDMI-1, HDMI-2, etc.)
OUT=$(xrandr | awk '/ connected/ {print $1; exit}')

# Optionally set resolution (some panels expose it as a mode)
if [ -n "${RESOLUTION:-}" ] && [ -n "${OUT:-}" ]; then
  xrandr --output "$OUT" --mode "$RESOLUTION" 2>/dev/null || true
fi

# Night dim loop
(
  while true; do
    H=$(date +%H)
    if [ -n "${OUT:-}" ]; then
      if [ "${H#0}" -ge "${NIGHT_START:-22}" ] || [ "${H#0}" -lt "${NIGHT_END:-7}" ]; then
        xrandr --output "$OUT" --brightness "${NIGHT_BRIGHTNESS:-0.20}" 2>/dev/null || true
      else
        xrandr --output "$OUT" --brightness "${DAY_BRIGHTNESS:-1.00}" 2>/dev/null || true
      fi
    fi
    sleep 60
  done
) &

# Launch selected mode.
# If active.conf points to vu-dual.conf, we run via xterm fullscreen for best results.
ACTIVE="$HOME/.config/roon-cava-display/active.conf"
if grep -q "method = noncurses" "$ACTIVE" 2>/dev/null; then
  exec xterm -fullscreen -bg black -fg white -e cava -p "$ACTIVE"
else
  exec cava -p "$ACTIVE"
fi
EOF
  chmod +x "$HOME/.xinitrc"

  # Bash profile startx
  local bp="$HOME/.bash_profile"
  if [[ ! -f "$bp" ]]; then
    touch "$bp"
  fi
  backup_file "$bp" >/dev/null || true
  if ! grep -qE '^[[:space:]]*startx[[:space:]]*$' "$bp"; then
    printf "\n# Auto-start CAVA display (added by roon-cava-display)\nstartx\n" >> "$bp"
  fi
}

write_asoundrc(){
  backup_file "$HOME/.asoundrc" >/dev/null || true

  local hdmi_pcm
  if [[ "$NO_HDMI_AUDIO" == "1" ]]; then
    hdmi_pcm="null"
  else
    if [[ -z "${HDMI_CARD:-}" || -z "${HDMI_DEV:-}" ]]; then
      log "WARNING: HDMI playback device not found (vc4hdmi). Using 'null' sink."
      hdmi_pcm="null"
    else
      hdmi_pcm="hw:${HDMI_CARD},${HDMI_DEV}"
    fi
  fi

  cat > "$HOME/.asoundrc" <<EOF
# Generated by roon-cava-display installer.
# Duplicates the default PCM stream to:
#   - ${hdmi_pcm} (HDMI out or null)
#   - hw:${LOOP_CARD},0,0 (Loopback playback side)
#
# CAVA reads from Loopback capture side: hw:${LOOP_CARD},1,0

pcm.tee {
    type multi
    slaves.a.pcm "${hdmi_pcm}"
    slaves.a.channels 2

    slaves.b.pcm "hw:${LOOP_CARD},0,0"
    slaves.b.channels 2

    bindings.0.slave a
    bindings.0.channel 0
    bindings.1.slave a
    bindings.1.channel 1
    bindings.2.slave b
    bindings.2.channel 0
    bindings.3.slave b
    bindings.3.channel 1
}

pcm.!default {
    type plug
    slave.pcm tee
}
EOF
}

enable_snd_aloop(){
  ensure_sudo
  log "Enabling snd-aloop (ALSA loopback)…"
  sudo modprobe snd-aloop || true
  sudo mkdir -p /etc/modules-load.d
  local f="/etc/modules-load.d/roon-cava-display-snd-aloop.conf"
  if [[ ! -f "$f" ]]; then
    echo "snd-aloop" | sudo tee "$f" >/dev/null
  fi
}

install_packages(){
  ensure_sudo
  log "Installing packages…"
  sudo apt update
  sudo apt install -y --no-install-recommends \
    curl ca-certificates \
    cava alsa-utils \
    xserver-xorg xinit xterm unclutter
}

install_roonbridge(){
  ensure_sudo
  # RoonBridge installer script places files in /opt/RoonBridge and sets service.
  if systemctl is-active --quiet roonbridge 2>/dev/null || systemctl status roonbridge >/dev/null 2>&1; then
    log "RoonBridge appears installed (systemd service exists). Skipping."
    return 0
  fi
  log "Installing RoonBridge…"
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSLO https://download.roonlabs.com/builds/roonbridge-installer-linuxarmv7hf.sh
    chmod +x roonbridge-installer-linuxarmv7hf.sh
    sudo ./roonbridge-installer-linuxarmv7hf.sh
  )
  rm -rf "$tmp"
}

write_manifest(){
  log "Writing manifest…"
  local created=()
  created+=("$HOME/.asoundrc")
  created+=("$HOME/.xinitrc")
  created+=("$HOME/.config/roon-cava-display/mirror-neon.conf")
  created+=("$HOME/.config/roon-cava-display/vu-dual.conf")
  created+=("$HOME/.config/roon-cava-display/active.conf")
  created+=("$HOME/.config/roon-cava-display/display.env")
  created+=("$HOME/.config/cava/config")
  created+=("$HOME/.bash_profile")
  local etc_file="/etc/modules-load.d/roon-cava-display-snd-aloop.conf"

  cat > "$MANIFEST_FILE" <<EOF
{
  "installed_at": "$STAMP",
  "backup_dir": "$BACKUP_DIR",
  "mode": "$MODE",
  "resolution": "$RESOLUTION",
  "no_hdmi_audio": "$NO_HDMI_AUDIO",
  "detected": {
    "loop_card": "${LOOP_CARD}",
    "hdmi_card": "${HDMI_CARD:-}",
    "hdmi_device": "${HDMI_DEV:-}"
  },
  "files_touched": $(python3 - <<'PY'
import json,sys
files = sys.stdin.read().splitlines()
PY
)
}
EOF
  # The python snippet above is a no-op; we'll just write properly below (simpler/robust).
  python3 - <<PY
import json, os
manifest = {
  "installed_at": "$STAMP",
  "backup_dir": "$BACKUP_DIR",
  "mode": "$MODE",
  "resolution": "$RESOLUTION",
  "no_hdmi_audio": "$NO_HDMI_AUDIO",
  "detected": {"loop_card": "${LOOP_CARD}", "hdmi_card": "${HDMI_CARD:-}", "hdmi_device": "${HDMI_DEV:-}"},
  "files_touched": [
    os.path.expanduser("~/.asoundrc"),
    os.path.expanduser("~/.xinitrc"),
    os.path.expanduser("~/.config/roon-cava-display/mirror-neon.conf"),
    os.path.expanduser("~/.config/roon-cava-display/vu-dual.conf"),
    os.path.expanduser("~/.config/roon-cava-display/active.conf"),
    os.path.expanduser("~/.config/roon-cava-display/display.env"),
    os.path.expanduser("~/.config/cava/config"),
    os.path.expanduser("~/.bash_profile"),
    "/etc/modules-load.d/roon-cava-display-snd-aloop.conf",
  ],
}
os.makedirs(os.path.dirname(os.path.expanduser("$MANIFEST_FILE")), exist_ok=True)
with open(os.path.expanduser("$MANIFEST_FILE"), "w") as f:
  json.dump(manifest, f, indent=2)
print("ok")
PY
}

main(){
  log "Starting install…"
  install_packages
  enable_snd_aloop

  # Re-detect after loopback is loaded
  detect_alsa_cards

  install_roonbridge
  write_asoundrc
  write_files
  write_manifest

  log "Done."
  echo
  echo "Next steps:"
  echo "  1) In Roon: Settings → Audio → enable the Raspberry Pi endpoint."
  echo "  2) Play audio to that zone."
  echo "  3) Reboot Pi (recommended): sudo reboot"
  echo
  echo "Switch modes:"
  echo "  Mirror neon: ln -sf ~/.config/roon-cava-display/mirror-neon.conf ~/.config/roon-cava-display/active.conf"
  echo "  VU dual:     ln -sf ~/.config/roon-cava-display/vu-dual.conf     ~/.config/roon-cava-display/active.conf"
  echo
  echo "Edit resolution/night dim:"
  echo "  nano ~/.config/roon-cava-display/display.env"
}

main "$@"
