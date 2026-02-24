# roon-cava-display (Pi Zero 2 W + HDMI 7" screen)

A tiny “always-on” **CAVA** visualizer display for **Roon**, designed for a Raspberry Pi (Pi Zero 2 W works great) with an HDMI touchscreen.

This solves the Windows/WASAPI exclusive-mode problem cleanly:

- Your **Windows 11** Roon Core can keep **Exclusive Mode** enabled.
- The Pi runs **RoonBridge** as a network endpoint.
- On the Pi, ALSA duplicates (“tees”) the audio stream into an **ALSA Loopback** device.
- **CAVA** reads the loopback capture stream and renders fullscreen.

## What this repo installs

`./install.sh` does the following with minimal prompts:

- Installs: `roonbridge`, `cava`, minimal `xorg` + `xinit`, `xterm`, `unclutter`, `alsa-utils`
- Enables ALSA loopback module (`snd-aloop`) persistently
- Creates `~/.asoundrc` that duplicates the default audio stream to:
  - HDMI audio out (`vc4hdmi`) **or** `null` (if `--no-hdmi-audio`)
  - ALSA Loopback playback (`Loopback,0,0`)
- Creates two CAVA presets:
  - `mirror-neon.conf` (pretty symmetric mirror + neon gradient)
  - `vu-dual.conf` (true L/R split using terminal renderer)
- Selects an active preset via `~/.config/roon-cava-display/active.conf`
- Creates `~/.xinitrc` to:
  - set screen resolution (best-effort)
  - apply night dim (xrandr brightness)
  - launch CAVA fullscreen (SDL for mirror, xterm for VU)
- Adds `startx` to `~/.bash_profile` (if not present) so it boots straight into the visualizer on login

`./uninstall.sh` restores backups and removes changes (it does **not** remove RoonBridge by default).

---

## Install

```bash
git clone https://github.com/YOURNAME/roon-cava-display.git
cd roon-cava-display
chmod +x install.sh uninstall.sh
./install.sh --resolution 1600x600 --mode mirror
sudo reboot
```

### Options

- `--resolution 1600x600`  
  Your screen resolution. Used by `xrandr --mode`. Some HDMI panels expose their mode; if not, this setting is harmless.

- `--mode mirror|vu`  
  Default is `mirror`.

- `--no-hdmi-audio`  
  Uses `null` instead of HDMI as the “real” sink. Still feeds the loopback for CAVA. Useful if you don’t want the Pi to output sound.

---

## Configure Roon

On your Windows Core:

1. **Settings → Audio**
2. Enable the Raspberry Pi endpoint (RoonBridge)
3. Select that zone and start playback

The Pi will receive the stream over RAAT; CAVA will react immediately.

---

## Change screen resolution

Edit:

```bash
nano ~/.config/roon-cava-display/display.env
```

Change:

```ini
RESOLUTION="1600x600"
```

If your panel supports that mode, `xrandr` will apply it on startup.

---

## Night dim mode

Also in `display.env`:

```ini
NIGHT_START="22"     # 22:00
NIGHT_END="7"        # 07:00
DAY_BRIGHTNESS="1.00"
NIGHT_BRIGHTNESS="0.20"
```

The dimmer uses `xrandr --brightness`. Not all panels react strongly (some do), but it’s the most universal software control.

---

## The two CAVA configuration files

### 1) `mirror-neon.conf` (recommended)

- Renderer: **SDL** (`output.method = sdl`)
- Look: **symmetric mirrored spectrum** (bars mirror from center)
- Aesthetic: **neon RGB gradient**
- Best for: “CAVA-on-a-strip-display” vibes

### 2) `vu-dual.conf` (true L/R split)

- Renderer: **noncurses** in a fullscreen terminal
- Look: **dual channel** (L and R separated, top/bottom)
- Best for: more “VU-ish” behavior

Because CAVA’s nicest fullscreen renderer is SDL, and the true L/R split mode is tied to the terminal output, this repo switches launch method automatically based on the active config.

---

## Select / switch modes

The active preset is a symlink:

`~/.config/roon-cava-display/active.conf`

Switch to mirror:

```bash
ln -sf ~/.config/roon-cava-display/mirror-neon.conf ~/.config/roon-cava-display/active.conf
```

Switch to VU dual:

```bash
ln -sf ~/.config/roon-cava-display/vu-dual.conf ~/.config/roon-cava-display/active.conf
```

Then restart X (or reboot):

```bash
sudo reboot
```

> If you *really* want the standard CAVA path, you can rename a preset to `~/.config/cava/config`, but this repo already symlinks that for you.

---

## Uninstall

```bash
cd roon-cava-display
./uninstall.sh
sudo reboot
```

This will:
- Restore backups for `~/.asoundrc`, `~/.xinitrc`, `~/.bash_profile` (if backed up), `~/.config/cava/config`
- Remove the persistent module-load file for `snd-aloop`

RoonBridge is left installed intentionally.

---

## Troubleshooting

### CAVA is flatlined

1. Confirm Roon is playing to the Pi endpoint.
2. Confirm loopback capture exists:

```bash
arecord -l
```

3. Confirm capture reads without error:

```bash
arecord -D hw:0,1,0 -f S16_LE -c 2 -r 44100 | head -c 2000 >/dev/null
```

If this errors, your loopback card number may differ. Re-run:

```bash
aplay -l
```

Then update CAVA `source` in the preset.

### My HDMI isn’t `vc4hdmi`

Some setups use different HDMI device names. The installer tries to auto-detect `vc4hdmi`; if not found, it falls back to `null` and still works for visualization.

---

## Notes / Safety

- This project only configures **your user’s** home directory files and a single `/etc/modules-load.d/*.conf` file.
- Backups are stored under `~/.roon-cava-backups/<timestamp>/`
- A manifest is stored in `~/.roon-cava-display/manifest.json`
