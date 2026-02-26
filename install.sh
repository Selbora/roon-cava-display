#!/usr/bin/env bash
set -euo pipefail

# roon-cava-display installer
# - DietPi / Debian-family friendly
# - Creates ALSA tee (HDMI/null + Loopback) so CAVA can visualize RoonBridge audio
# - Sets up minimal X autostart into CAVA fullscreen with night dim
#
# Usage:
#   ./install.sh [--resolution 1600x600] [--mode mirror|vu] [--no-roonbridge]
#
# Notes:
# - Requires: Raspberry Pi Zero 2 W (recommended) + HDMI display
# - RoonBridge zone must output to ALSA "default" (we set pcm.!default via ~/.asoundrc)

APP_NAME="roon-cava-display"
CFG_DIR="${HOME}/.config/${APP_NAME}"
BACKUP_ROOT="${HOME}/.roon-cava-backups"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"

MODE="mirror"
RESOLUTION=""
INSTALL_ROONBRIDGE=1

log(){ printf '[%s] %s\n' "${APP_NAME}" "$*"; }
warn(){ printf '[%s] WARNING: %s\n' "${APP_NAME}" "$*" >&2; }
die(){ printf '[%s] ERROR: %s\n' "${APP_NAME}" "$*" >&2; exit 1; }

usage(){
  cat <<'EOF'
roon-cava-display installer

Options:
  --resolution WxH     Force X display mode (e.g. 1600x600). Leave unset to skip.
  --mode mirror|vu     Choose default mode:
                         mirror = SDL fullscreen neon mirrored spectrum (recommended)
                         vu     = terminal fullscreen L/R split (closest to "dual channel")
  --no-roonbridge      Do not install RoonBridge (leave existing install as-is)
  -h, --help           Show help

Example:
  ./install.sh --resolution 1600x600 --mode mirror
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resolution)
      RESOLUTION="${2:-}"; shift 2;;
    --mode)
      MODE="${2:-}"; shift 2;;
    --no-roonbridge)
      INSTALL_ROONBRIDGE=0; shift;;
    -h|--help)
      usage; exit 0;;
    *)
      die "Unknown arg: $1 (use --help)";;
  esac
done

[[ "$MODE" == "mirror" || "$MODE" == "vu" ]] || die "--mode must be mirror or vu"

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

ensure_sudo(){
  if ! sudo -n true >/dev/null 2>&1; then
    log "Requesting sudo..."
    sudo true || die "Sudo failed"
  fi
}

mkdir -p "$CFG_DIR"
mkdir -p "$BACKUP_DIR"

backup_file(){
  local p="$1"
  if [[ -e "$p" || -L "$p" ]]; then
    local rel="${p#/}"              # strip leading slash
    local dest="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$p" "$dest"
    log "Backed up: $p -> $dest"
  fi
}

install_packages(){
  ensure_sudo
  log "Installing packages..."
  sudo apt-get update -y
  # minimal X + fullscreen terminal support + cursor hiding
  sudo apt-get install -y --no-install-recommends \
    cava alsa-utils xserver-xorg xinit xterm unclutter x11-xserver-utils
}

enable_snd_aloop(){
  ensure_sudo
  log "Enabling ALSA loopback module (snd_aloop)..."
  if ! sudo modprobe snd_aloop; then
    die "modprobe snd_aloop failed. Check: modinfo snd_aloop"
  fi
  if ! lsmod | grep -q '^snd_aloop'; then
    die "snd_aloop did not appear in lsmod after modprobe."
  fi

  # Persist across reboots
  sudo mkdir -p /etc/modules-load.d
  local f="/etc/modules-load.d/${APP_NAME}-snd-aloop.conf"
  if [[ ! -f "$f" ]]; then
    echo "snd_aloop" | sudo tee "$f" >/dev/null
    log "Created $f"
  else
    log "Exists: $f"
  fi
}

detect_cards(){
  need_cmd aplay
  need_cmd arecord
  local aplay_out arecord_out
  aplay_out="$(aplay -l 2>/dev/null || true)"
  arecord_out="$(arecord -l 2>/dev/null || true)"

  # Loopback card number (robust across formats)
  LOOP_CARD="$(
    printf "%s\n%s\n" "$aplay_out" "$arecord_out" | \
    awk -F'[: ]+' 'tolower($0) ~ /^card [0-9]+: loopback/ {print $2; exit}'
  )"

  if [[ -z "${LOOP_CARD:-}" ]]; then
    echo "Debug: aplay -l:" >&2
    echo "$aplay_out" >&2
    echo "Debug: arecord -l:" >&2
    echo "$arecord_out" >&2
    die "Could not find ALSA Loopback card in aplay/arecord output. Is snd_aloop loaded?"
  fi

  # HDMI card number preference: vc4-hdmi on Raspberry Pi
  HDMI_CARD="$(
    echo "$aplay_out" | awk -F'[: ]+' '
      tolower($0) ~ /^card [0-9]+: vc4hdmi/ {print $2; exit}
      tolower($0) ~ /^card [0-9]+: vc4-hdmi/ {print $2; exit}
    '
  )"

  log "Detected Loopback card: $LOOP_CARD"
  if [[ -n "${HDMI_CARD:-}" ]]; then
    log "Detected HDMI card: $HDMI_CARD"
  else
    warn "No vc4-hdmi playback card detected; will tee to null sink (no audio out)."
  fi
}

install_roonbridge(){
  if [[ "$INSTALL_ROONBRIDGE" -eq 0 ]]; then
    log "Skipping RoonBridge install (--no-roonbridge)."
    return
  fi

  # Detect existing install
  if systemctl list-unit-files 2>/dev/null | grep -q '^roonbridge\.service'; then
    log "RoonBridge service already present; skipping install."
    return
  fi

  ensure_sudo
  log "Installing RoonBridge..."
  local tmp="/tmp/roonbridge-installer.sh"
  curl -fsSL -o "$tmp" "https://download.roonlabs.com/builds/roonbridge-installer-linuxarmv7hf.sh" \
    || die "Failed to download RoonBridge installer"
  chmod +x "$tmp"
  sudo "$tmp" || die "RoonBridge installer failed"
  log "RoonBridge installed."
}

write_asoundrc(){
  local out_pcm
  if [[ -n "${HDMI_CARD:-}" ]]; then
    out_pcm="hw:${HDMI_CARD},0"
  else
    out_pcm="null"
  fi

  backup_file "${HOME}/.asoundrc"

  cat > "${HOME}/.asoundrc" <<EOF
# ${APP_NAME} - generated $(date)
# Duplicates default PCM stream to:
#  - ${out_pcm} (HDMI if detected, else null)
#  - ALSA Loopback playback side (hw:${LOOP_CARD},0)
#
# CAVA should capture from loopback capture side:
#  - hw:${LOOP_CARD},1,0

pcm.${APP_NAME}_tee {
    type multi
    slaves.a.pcm "${out_pcm}"
    slaves.a.channels 2

    slaves.b.pcm "hw:${LOOP_CARD},0"
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
    slave.pcm ${APP_NAME}_tee
}
EOF

  log "Wrote ~/.asoundrc (tee -> ${out_pcm} + loopback)"
}

write_cava_configs(){
  mkdir -p "${CFG_DIR}"

  cat > "${CFG_DIR}/mirror-neon.conf" <<EOF
# Mirror Neon preset (1600x600 tuned)
[general]
framerate = 60
autosens = 1
bars = 200
bar_width = 6
bar_spacing = 2

[input]
method = alsa
source = hw:${LOOP_CARD},1,0

[output]
method = sdl
sdl_full_screen = 1
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

  cat > "${CFG_DIR}/vu-dual.conf" <<EOF
# "VU-style" dual channel preset (closest native L/R separation)
[general]
framerate = 60
autosens = 1

[input]
method = alsa
source = hw:${LOOP_CARD},1,0

[output]
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

  # Active config pointer
  if [[ "$MODE" == "mirror" ]]; then
    ln -sf "${CFG_DIR}/mirror-neon.conf" "${CFG_DIR}/active.conf"
  else
    ln -sf "${CFG_DIR}/vu-dual.conf" "${CFG_DIR}/active.conf"
  fi

  # Convenience: also set default cava config path to active.conf
  mkdir -p "${HOME}/.config/cava"
  backup_file "${HOME}/.config/cava/config"
  cat > "${HOME}/.config/cava/config" <<EOF
# ${APP_NAME} - CAVA default config redirects to active preset
# Change mode by repointing: ${CFG_DIR}/active.conf
# Example:
#   ln -sf ${CFG_DIR}/mirror-neon.conf ${CFG_DIR}/active.conf
#   ln -sf ${CFG_DIR}/vu-dual.conf ${CFG_DIR}/active.conf
# Then restart X/CAVA.
include = ${CFG_DIR}/active.conf
EOF

  log "Wrote CAVA presets + active.conf symlink + ~/.config/cava/config include"
}

write_display_env(){
  cat > "${CFG_DIR}/display.env" <<EOF
# ${APP_NAME} display settings
# Set RESOLUTION to force a mode via xrandr. Leave empty to skip.
RESOLUTION="${RESOLUTION}"

# Night dim schedule (24h)
NIGHT_START="22"
NIGHT_END="7"
BRIGHT_DAY="1.00"
BRIGHT_NIGHT="0.20"

# Default mode: mirror or vu
MODE="${MODE}"
EOF
  log "Wrote ${CFG_DIR}/display.env"
}

write_xinitrc(){
  backup_file "${HOME}/.xinitrc"

  cat > "${HOME}/.xinitrc" <<'EOF'
#!/bin/sh
set -eu

CFG_DIR="$HOME/.config/roon-cava-display"
# shellcheck disable=SC1090
. "$CFG_DIR/display.env" 2>/dev/null || true

xset -dpms
xset s off
xset s noblank

# Hide cursor quickly
command -v unclutter >/dev/null 2>&1 && unclutter -idle 0.1 -root &

# Detect first connected output
OUT=$(xrandr | awk '/ connected/ {print $1; exit}')

# Optional fixed resolution
if [ -n "${RESOLUTION:-}" ] && [ -n "${OUT:-}" ]; then
  xrandr --output "$OUT" --mode "$RESOLUTION" 2>/dev/null || true
fi

# Night dim loop (22:00–07:00 by default)
(
  while true; do
    H=$(date +%H)
    if [ -n "${OUT:-}" ]; then
      if [ "$H" -ge "${NIGHT_START:-22}" ] || [ "$H" -lt "${NIGHT_END:-7}" ]; then
        xrandr --output "$OUT" --brightness "${BRIGHT_NIGHT:-0.20}" 2>/dev/null || true
      else
        xrandr --output "$OUT" --brightness "${BRIGHT_DAY:-1.00}" 2>/dev/null || true
      fi
    fi
    sleep 60
  done
) &

# Launch CAVA
if [ "${MODE:-mirror}" = "vu" ]; then
  exec xterm -fullscreen -bg black -fg white -e cava -p "$CFG_DIR/active.conf"
else
  exec cava -p "$CFG_DIR/active.conf"
fi
EOF

  chmod +x "${HOME}/.xinitrc"
  log "Wrote ~/.xinitrc (autostart CAVA + night dim)"
}

enable_autostart_x(){
  # Start X on interactive login (console)
  local bp="${HOME}/.bash_profile"
  backup_file "$bp"

  if [[ -f "$bp" ]] && grep -q 'startx' "$bp"; then
    log "~/.bash_profile already contains startx"
    return
  fi

  {
    echo ""
    echo "# ${APP_NAME} - auto start X on TTY login"
    echo "if [ -z \"\${DISPLAY:-}\" ] && [ \"\${XDG_VTNR:-}\" = \"1\" ]; then"
    echo "  command -v startx >/dev/null 2>&1 && exec startx"
    echo "fi"
  } >> "$bp"

  log "Appended startx autostart block to ~/.bash_profile"
}

summary(){
  cat <<EOF

✅ Installation complete.

Next steps:
1) Reboot:
   sudo reboot

2) In Roon on Windows:
   Settings → Audio → enable the RoonBridge zone for this Pi.
   Play to that zone.

3) Switch modes:
   ln -sf "${CFG_DIR}/mirror-neon.conf" "${CFG_DIR}/active.conf"   # mirror neon
   ln -sf "${CFG_DIR}/vu-dual.conf" "${CFG_DIR}/active.conf"      # dual channel-ish
   Then restart X (reboot easiest).

4) Change resolution / night dim:
   nano "${CFG_DIR}/display.env"

Backups created in:
  ${BACKUP_DIR}

EOF
}

main(){
  need_cmd curl
  install_packages
  enable_snd_aloop
  detect_cards
  install_roonbridge
  write_asoundrc
  write_cava_configs
  write_display_env
  write_xinitrc
  enable_autostart_x
  summary
}

main "$@"
