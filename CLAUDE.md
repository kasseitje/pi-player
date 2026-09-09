# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`pi-player` is a **scaffold**, not a buildable project. It holds the two things
that get copied into a separate [pi-gen](https://github.com/RPi-Distro/pi-gen)
clone, plus workstation tooling that never ships:

| Path | Runs where | Ships in image |
|---|---|---|
| `config` | pi-gen build | no (it *is* the build config) |
| `stage-player/` | pi-gen build | yes |
| `host-tools/` | your workstation | no |
| `README.md`, `CLAUDE.md` | — | no |

The build itself happens in `~/Development/pi-gen` (branch `arm64`), where
`config` and `stage-player/` are **copies**. Edits made there do not flow back
here. Treat this repo as the master copy and re-copy after every change:

```bash
cp -r ~/Development/pi-player/stage-player ~/Development/pi-gen/stage-player
cp    ~/Development/pi-player/config       ~/Development/pi-gen/config
```

Product: a Pi 4 appliance that boots straight into a looping mpv playlist on
bare DRM/KMS — no desktop, no login prompt. Media comes from a USB stick; a
baked-in title card plays when none is present. Built for an unattended
neighbourhood-committee event (schedule, sponsors, photo archive going back to
1993). Originally scoped as "video booth with infopanel", narrowed early to a
plain looping player — no capture, no camera. A Pi 3 is used for testing.

`README.md` is the end-to-end build and operations guide, with a
runtime-focused troubleshooting table. **This file is the design record** — the
rationale, the dead ends already walked, and the unfinished work. There was a
separate `HANDOFF.md`; it has been folded in here and deleted.

## Commands

There are no tests, no linter, and no build step in this repo. Verification is:
build an image, flash it, boot it, read the journal.

**Build** (in the pi-gen clone, not here):

```bash
cd ~/Development/pi-gen
git fetch --depth 1 origin arm64 && git checkout -B arm64 FETCH_HEAD
rm stage2/EXPORT_IMAGE          # else you get a second, stock "-lite" image
sudo ./build-docker.sh          # ~20-60 min first time; output in deploy/
```

`git update-index --skip-worktree stage2/EXPORT_IMAGE` stops a later `git pull`
restoring it.

**Iterate on the stage only** (minutes, not a full rebuild):

```bash
sudo rm -f work/pi-player/stage-player/SUCCESS
sudo CONTINUE=1 ./build-docker.sh
```

Clean rebuild: `sudo rm -rf work deploy`.

**Host prerequisites** — install `binfmt-support` *first*; the qemu packages
register handlers in a postinst hook and silently no-op without it:

```bash
sudo apt install -y binfmt-support
sudo apt install -y qemu-user qemu-user-binfmt docker.io git imagemagick ffmpeg
```

Handlers must carry the `F` (fix-binary) flag, or the interpreter path is
resolved inside the container's mount namespace where it does not exist.
Registrations are lost on reboot:

```bash
grep -E 'enabled|interpreter|flags' /proc/sys/fs/binfmt_misc/qemu-aarch64
docker run --privileged --rm tonistiigi/binfmt --install arm,arm64
```

**Flash**: `rpi-imager` → *Use custom* → the image **without** `-lite` → at the
customisation prompt choose **"No, clear settings"**. Imager's `firstrun.sh`
fights the baked-in boot target and user setup.

**Prepare media** (workstation):

```bash
./host-tools/prepare-media.sh SRCDIR DSTDIR
IMAGE_DURATION=8 CRF=22 ./host-tools/prepare-media.sh ~/raw /media/STICK
```

Env overrides: `IMAGE_DURATION` (5) `WIDTH` (1920) `HEIGHT` (1080) `FPS` (30)
`CRF` (20) `PRESET` (medium) `BG` (black) `PLAYLIST` (1) `KEEP_NAMES` (0)
`FIT` (contain) `BLUR_SIGMA` (8).

`FIT` decides what happens to content that is not 16:9 — which is most of a
photo archive:

| `FIT` | Result | Cost |
|---|---|---|
| `contain` | fits inside, `BG` bars baked into the frame | nothing lost, but a portrait photo is mostly black bar |
| `cover` | fills the canvas, crops the overflow | edges lost; brutal on portrait |
| `blur` | blurred zoomed copy of the image fills the canvas, uncropped image on top | nothing lost, no bars; ~1 extra scale pass |

Verified: with `FIT=blur` the centre of a 1000x1500 portrait measures the same
average luma as under `FIT=contain` (129.863) while the left edge goes from 16
(black) to 235 — the image itself is untouched, only the bars are replaced.
`FIT=cover` changes the centre too (125.25), because it zooms.
Only reads the top level of `SRCDIR`. Every output is verified by packet count
and duration; failures are deleted, listed, and the script exits non-zero — a
zero-frame "successful" encode is exactly how a black frame gets into a loop
unnoticed.

**Re-render the fallback title card:**

```bash
./host-tools/make-title-card.sh OUT [LOGO] [HEADLINE] [SUBLINE] [EYEBROW] [FOOTER] [SECONDS]
```

Keep `SECONDS` a multiple of 2.5 — the eyebrow pulses on that period and any
other length makes the loop seam visible (currently ~48 dB PSNR first-to-last
frame). Text goes through ffmpeg's `textfile=`, not `text=`; the latter breaks
on apostrophes (a Dutch subline once vanished silently).

**Verify on the booted Pi:**

```bash
journalctl -u player.service -b                 # the real error; the console loop hides it
cat /run/player/playlist.m3u                    # what is actually queued
journalctl -f -t usb-media-attach -t player-playlist -t player-reload
journalctl -u player.service -b | grep -i "hardware decoding"
echo '{"command":["get_property","filename"]}' | socat - /run/player/mpv.sock
vcgencmd get_throttled                          # non-zero = it has been throttling
```

## Architecture

Three execution contexts, easy to confuse. Every file belongs to exactly one.

### 1. Build time — `stage-player/` (a pi-gen stage)

pi-gen runs numbered subdirectories in order; `NN-run.sh` executes on the host
against `${ROOTFS_DIR}`, `NN-run-chroot.sh` executes inside the target rootfs.

- `00-install-packages/00-packages` — mpv, socat, exfatprogs, ntfs-3g, …
- `01-player-files/00-run.sh` (host) — installs `files/` into the rootfs
- `01-player-files/01-run-chroot.sh` (chroot) — rewrites `User=`/`Group=` in
  `player.service` from `FIRST_USER_NAME`, sets `multi-user.target`, disables
  `getty@tty1`, adds the user to `video,render,input`
- `02-boot-config/00-run.sh` (host) — appends to `cmdline.txt` / `config.txt`
- `EXPORT_IMAGE` carries `IMG_SUFFIX=""`, so the player image is the one
  *without* `-lite`

**Architecture and Debian release come from the pi-gen git branch, not from
`config`.** Setting `ARCH=`/`RELEASE=` there does nothing and warns. Use
`arm64` (covers Pi 3/4/5, and avoids an armhf-only SHA-1 archive-key failure in
stage0). `STAGE_LIST` stops at `stage-player`, so the desktop stages 3/4/5
never run and no SKIP files are needed.

### 2. Runtime — `stage-player/01-player-files/files/`

```
boot (multi-user.target)
  └── player.service        User=<FIRST_USER_NAME>, PAMName=login, TTYPath=/dev/tty1
        └── player-run      sources /etc/default/player
              ├── player-playlist   → /run/player/playlist.m3u
              └── mpv --gpu-context=drm --input-ipc-server=/run/player/mpv.sock

USB insert
  └── 99-usb-media.rules sets SYSTEMD_WANTS (no RUN+=)
        └── usb-media@sdX1.service    BindsTo=dev-sdX1.device
              ├── ExecStart usb-media-attach   mount ro → playlist → reload
              └── ExecStop  usb-media-detach   unmount → playlist → reload
                    └── player-reload   loadlist replace over the IPC socket
```

Playlist precedence in `player-playlist`:

1. `/media/usb/playlist.m3u` exists → use it, **directory scan skipped entirely**
2. USB mounted, no m3u, scan finds media → use the scan
3. USB mounted, neither → unmount, fall back to internal
4. No USB → scan `/opt/player/media` (the title card)

`.m3u` entries resolve relative to the stick root, so they reach arbitrary
depth regardless of the scan's `-maxdepth 2` limit. CRLF and `#` comments are
tolerated; backslash separators are **not** translated.

### 3. Workstation — `host-tools/`

Never installed on the Pi. `prepare-media.sh` normalises clips *and stills* to
1920x1080@30, H.264 High L4.1, yuv420p, SAR 1:1, no audio, fixed 2s GOP.
Stills are **composited onto a canvas**, not `pad`ded — `pad` discards alpha.
Under `FIT=blur` the rate conversion happens *before* the `split`, so both
branches stay frame-locked; doing it after the `overlay` lets them drift and
costs one frame per clip.
Files ffmpeg cannot decode are retried through ImageMagick (`-colorspace
sRGB`), which handles CMYK JPEGs. GIFs longer than `IMAGE_DURATION` are
**truncated**, not slowed. Verified against fixtures covering progressive JPEG,
CMYK, grayscale, RGBA PNG, odd dimensions (1999x1333), animated GIF, static GIF
and video — all converge on byte-identical stream parameters.

`make-title-card.sh` renders the fallback card baked in at
`stage-player/01-player-files/files/media/000_fallback.mp4`.

## Non-obvious constraints

**DRM master needs a real VT *and* a logind session.** Hence `PAMName=login` +
`TTYPath=/dev/tty1` in the unit. Without both: `VT_GETMODE: Inappropriate
ioctl`, then `Failed to acquire DRM master: Permission denied`. This is also
why the player **cannot be tested over SSH or with `sudo -u`** — no seat, no
`XDG_RUNTIME_DIR`. Log in on the console or use `machinectl shell`.

**No compositor, ever.** A desktop session holds DRM master and makes
`--gpu-context=drm` impossible. That is why `01-run-chroot.sh` forces
`multi-user.target` and disables `getty@tty1`.

**One Pi per screen.** DRM master is exclusive per *card*, not per connector —
the Pi 4's dual HDMI does not give two independent mpv processes. (An earlier
claim that it does was wrong.) Driving two screens from one board requires a
compositor, i.e. the layer deliberately removed.

**udev must not do the work.** udev kills `RUN+=` processes on a short timeout;
mount + scan + IPC exceeds it. The rule only sets `SYSTEMD_WANTS`.
`BindsTo=dev-%i.device` makes removal stop the unit and run `ExecStop`, so
unplug handling is free rather than a second racing rule.

**Reload over IPC, never restart mpv.** A fresh mpv re-opens `/dev/dri/card0`,
re-negotiates the mode and re-inits GL — a second or more of black screen, plus
a race where the DRM node is not yet released. `loadlist … replace` costs one
frame. `player-reload` falls back to `systemctl restart --no-block` only if the
socket is unreachable.

**Stills are converted to video, not displayed as images.** mpv's V4L2/GL path
on a Pi renders progressive, CMYK, grayscale, 16-bit and RGBA images green or
black, with no per-format hwdec switch. This was confirmed as an upstream
*decode* problem, not a display-path one — it reproduces identically under
`cage`/Wayland. Encoding stills as clips removes the failure mode, gives every
entry a real container duration (needed by the planned multi-screen scheduler),
and eliminates the mode-change flash between items. Consequence:
`IMAGE_DURATION` in `/etc/default/player` only matters for stills that reach
the stick *unconverted*.

**The USB stick is mounted read-only** (`ro,noatime,nosuid,nodev,noexec`). It
is content, never a write target; a stick pulled mid-playback cannot leave a
dirty filesystem. `usb-media-attach` refuses any device on the boot disk. Pairs
with the overlay rootfs.

## Bugs already fixed — do not re-derive

Chronological, from the build-out session. Several cost real time.

| Symptom | Cause | Fix |
|---|---|---|
| `libplacebo: Found no suitable device` | `gpu-next` defaults to Vulkan; VideoCore IV has no Vulkan driver | `--gpu-api=opengl` (now in `MPV_VO_OPTS`) |
| `cannot load libcuda.so.1`, VDPAU errors | `auto-safe` probes every compiled-in backend | Cosmetic. Ignore |
| `VT_GETMODE`, `Failed to acquire DRM master` | Run from a GUI terminal / SSH — compositor holds master, no seat | Only works on bare console via the service |
| 300% CPU on Pi 3 | `auto-safe` silently fell back to software decode | `--hwdec=v4l2m2m-copy` |
| `qemu-arm not found (please install qemu-user-binfmt)` | Debian trixie replaced `qemu-user-static` with `qemu-user`; pi-gen looks for `qemu-arm` | `apt install qemu-user qemu-user-binfmt`, with `binfmt-support` installed **first** |
| `armhf: not supported on this machine/kernel` | binfmt handlers registered without the `F` flag → interpreter path unresolvable inside the container | `docker run --privileged --rm tonistiigi/binfmt --install arm,arm64` |
| `E: Invalid Release signature` in stage0 | armhf-only: bundled Raspberry Pi archive key uses SHA-1, rejected by modern GnuPG | Use the `arm64` branch (bootstraps from Debian, not Raspbian) |
| `RELEASE does not match … this branch` | `ARCH=`/`RELEASE=` are **not** config variables; branch selects both | Removed from `config` |
| Two images in `deploy/` | `stage2/EXPORT_IMAGE` also exports | `rm stage2/EXPORT_IMAGE`; player image has no `-lite` suffix |
| Boots to a login prompt, wrong hostname | Wrong SD card in the slot (an old `upsmon` system) | Check `/etc/hostname` on the card itself |
| `Failed to determine user credentials: No such process`, restart loop | Unit hardcoded `User=pi`; `FIRST_USER_NAME` differed. `usermod … \|\| true` hid it at build time | `01-run-chroot.sh` rewrites `User=`/`Group=` and hard-fails if the user is missing |
| Repeated "Started player.service" on console | `Restart=always` retries forever, hiding the real error | Read `journalctl -u player.service -b` |
| `Unknown key 'StartLimitIntervalSec' in section [Service], ignoring`, and the service gives up for good after ~5 restarts | systemd moved the directive to `[Unit]` in v229; in `[Service]` it is silently ignored, reinstating the default 5-starts-in-10s limit — the exact opposite of what the comment claimed | `StartLimitIntervalSec=0` now lives in `[Unit]` |
| Service says `active (running)` but there is no picture; Main PID is still `player-run`, `Tasks: 0`, CPU frozen at ~80ms | `player-playlist` ran `mv` **without `-f`** over a `/run/player/playlist.m3u` that `usb-media-attach` had written **as root**. `mv` prompts `replace ... overriding mode 0644?` when the target is not writable and stdin is a tty — and `StandardInput=tty` hands it tty1 to block on forever, so `player-run` never reaches `exec mpv` | `mv -f` on both moves in `player-playlist` |
| Player only restarts after `systemctl stop getty@tty1 autovt@tty1` | logind respawns `autovt@tty1.service` (a separate symlink to `getty@.service`) when the player releases VT1. `systemctl disable getty@tty1` does not prevent this | `NAutoVTs=0` / `ReserveVT=0` logind drop-in, plus `After=getty@tty1.service` next to the existing `Conflicts=` |
| `Main process exited, code=exited, status=4/NOPERMISSION` on every stop/restart | mpv returns 4 when it quits on a signal; systemd's label for exit code 4 is misleading, it is not a permission problem | `SuccessExitStatus=4` |
| Photos green / black / miscoloured | Upstream decode bug, **not** the display path — reproduces under `cage`/Wayland. Progressive, CMYK, grayscale, RGBA, odd-dimension images | Convert stills to video via `prepare-media.sh` |
| GIFs lost their animation | `-loop 1` is an image2 demuxer option; the gif demuxer aborts with "Option loop not found", so every GIF fell to the ImageMagick fallback, which flattens frame 0 | `-ignore_loop 0` for `.gif` |
| `XDG_RUNTIME_DIR is not set` under `sudo -u` | No login session, so `pam_systemd` never created `/run/user/<uid>` | Log in as that user on the console, or `machinectl shell` |

## Conventions to preserve

- All tunables live in `/etc/default/player`; scripts source it. Never hardcode
  paths or mpv options into units or scripts.
- `player.service` ships `User=pi`; `01-run-chroot.sh` rewrites it from
  `FIRST_USER_NAME`. Keep the two in sync.
- **Build-time scripts fail loudly.** A `|| true` on `usermod` is precisely
  what shipped a broken image once; `01-run-chroot.sh` now hard-fails if the
  user is missing. Do not add `|| true` to anything whose failure would produce
  a non-booting player.
- Media entering the playlist must match 1920x1080@30, H.264 High L4.1,
  yuv420p, SAR 1:1, no audio, 2s GOP — otherwise mpv flashes on item change and
  seeks become unpredictable.
- `player-playlist` writes atomically and exits non-zero on an empty playlist;
  callers rely on that exit status to decide whether to revert to internal media.
- **Nothing run by `player.service` may prompt.** The unit sets
  `StandardInput=tty` on tty1, so any command that can ask a question will block
  there forever with no visible error. Force non-interactive flags (`mv -f`,
  `rm -f`, `cp -f`) in everything the service calls.
- `player-playlist` runs as **root** from `usb-media-attach` and as the **player
  user** from `player-run`, so files in `/run/player` change owner between runs.
  Do not assume the previous run's files are writable.

## Pi 3 testing deltas

The arm64 image boots unchanged, but two defaults assume a Pi 4:

- `/etc/default/player`: pin `--hwdec=v4l2m2m-copy` (the shipped
  `--hwdec=auto-safe` silently falls back to software decode → 300% CPU)
- `config.txt`: `cma-128` instead of `cma-256` against the Pi 3's fixed 1 GB

1080p copy-back drops frames on a Pi 3 — memory bandwidth, not decode. Expected;
do not tune the image around it. Use 720p test content if it distracts.

## Open items

Discussed and code-sketched, **not applied to the stage**:

1. Recursive scan + dotfile exclusion in `player-playlist` — the scan is
   `-maxdepth 2` and deeper files are silently skipped. Dropping `-maxdepth`
   needs `-not -path '*/.*'` alongside it: macOS `._` AppleDouble files decode
   as zero-length and break playback.
2. Empty-`.m3u` fallthrough to directory scan. An m3u whose entries are all
   missing currently yields an empty playlist and a black screen with no
   fallback. One-line fix:
   ```bash
   usb-m3u) expand_m3u "$SOURCE" > "$TMP"; [ -s "$TMP" ] || scan_dir "$USB_MOUNT_DIR" > "$TMP" ;;
   ```
3. Flexible playlist filename. `playlist.m3u` is hardcoded and case-sensitive on
   ext4 but case-insensitive on FAT32/exFAT — an inconsistency worth removing.
   Either `PLAYLIST_NAME` in `/etc/default/player`, or accept any
   `*.m3u`/`*.m3u8` in the stick root.
4. `hdmi_force_hotplug=1` / `hdmi_blanking=0` in `02-boot-config/00-run.sh` are
   legacy firmware settings, **inert** under `vc4-kms-v3d` — remove them. The
   KMS equivalent, worth adding if the venue display is powered on after the Pi,
   is a `cmdline.txt` argument: `video=HDMI-A-1:1920x1080@60D` (trailing `D`
   forces the connector enabled regardless of hotplug detect).
5. Verify pi-gen's own `resize` token in `cmdline.txt` survived the `tr -d '\n'`
   rewrite in `02-boot-config/00-run.sh`. If that stage broke first-boot
   filesystem expansion, the card silently never grows.

Shuffle caveat: `MPV_EXTRA_OPTS="--shuffle"` shuffles once at startup, not per
loop, and may not survive a `loadlist` swap. `{"command":["playlist-shuffle"]}`
over IPC is the explicit form.

Not done, recommended before unattended running: overlay rootfs (`raspi-config`
→ Performance Options → Overlay File System), which makes the rootfs read-only
with a RAM overlay so power loss cannot corrupt the card. Disable it
temporarily to change baked-in media or config. `FIRST_USER_PASS` in `config`
is still the placeholder and `ENABLE_SSH=1` uses password auth.

## Next phase: multiple screens in sync

Designed in detail, **not implemented**. Core decisions:

**One Pi per screen** (see Non-obvious constraints). **Do not** attempt a
master/slave design.

**Sync via shared wall clock, not a master.** Every node computes position
independently:

```
elapsed = (now - epoch) mod loop_duration
item    = entry whose [offset, offset+duration) contains elapsed
seek_to = elapsed - item.offset
```

A rebooted node rejoins mid-loop correctly with no negotiation; the broker going
down costs control, not sync; adding a screen is plug-in-and-go.

Needs a manifest with precomputed durations (an ffprobe pass over the prepared
media — this is why stills became video):

```json
{"content_hash":"sha256:…","epoch":1757376000,"loop_duration":137.4,
 "items":[{"file":"…/001.mp4","offset":0.0,"duration":12.0}]}
```

- **Clock:** chrony, one node as local server, wired Ethernet. Sub-ms, an order
  of magnitude better than needed. Not PTP — Pi NIC hardware timestamping is
  inconsistent and buys nothing here. Wi-Fi jitter would eat the whole budget.
- **Correction:** hard seek via `loadfile … {"start": …}` only above ~1s error;
  between 20ms and 1s nudge `speed` within ±0.2% to converge over ~10s;
  deadband below 20ms or it oscillates visibly. Add
  `--video-sync=display-resample`.
- **Achievable tolerance:** ±1 frame between adjacent screens, yes. Sub-frame
  video-wall genlock, no — independent pixel clocks, no framelock hardware.
  Design content so a bezel-spanning fast pan never happens.
- **Control plane:** MQTT (mosquitto), topics `signage/cmd/{all,node}`,
  `signage/manifest` (retained), `signage/state/<node>` (retained, last-will for
  offline detection). Heartbeat carries `playlist-pos`, `playback-time`,
  `drift_ms`, `content_hash` and `vcgencmd get_throttled` — thermal throttling
  at a venue shows up as stutter and is otherwise invisible.
- **Content distribution:** keep USB as the offline path. Add an rsync pull
  triggered by a manifest hash mismatch, staged then atomically renamed,
  switching at a loop boundary so all screens change together with no explicit
  coordination.
- **Shuffle is incompatible with this** — nodes must share a deterministic
  order. Shuffle once centrally and bake the result into the manifest.

**Build order:** (1) two Pis, chrony, same content, no sync logic — measure
drift over an hour; (2) wall-clock scheduler with hard seeks only; (3) speed
correction if the seeks are visible; (4) MQTT last. Steps 1–2 are ~150 lines of
Python and cover the requirement.

Additions this would need: `player-sync.py` + `player-sync.service`
(`After=player.service`), `player-manifest`, packages `python3-paho-mqtt` and
`chrony`, and `NODE_ID` / `MQTT_BROKER` / `SYNC_EPOCH` / `SYNC_ENABLED` in
`/etc/default/player`. `player-playlist`, the udev handoff and the DRM
mechanism are unchanged.
