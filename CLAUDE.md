# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**`README.md` is the human-facing build and operations guide** — prerequisites,
step-by-step build, flashing, USB preparation, tuning, troubleshooting. Don't
duplicate it here, and keep it in sync when behaviour changes. This file is the
*design record*: why things are the way they are, what has already been tried,
and what is deliberately unfinished.

## What this repo is

`pi-player` is a **scaffold**, not a buildable project. Two things get copied
into a separate [pi-gen](https://github.com/RPi-Distro/pi-gen) clone; the rest
never ships:

| Path | Runs where | Ships in image |
|---|---|---|
| `config` | pi-gen build | no (it *is* the build config) |
| `stage-player/` | pi-gen build | yes |
| `host-tools/` | workstation | no |
| `README.md`, `CLAUDE.md` | — | no |

The build happens in `~/Development/pi-gen` (branch `arm64`), where `config` and
`stage-player/` are **copies**. Edits there do not flow back. This repo is the
master copy; re-sync after every change:

```bash
rsync -a --delete ~/Development/pi-player/stage-player/ ~/Development/pi-gen/stage-player/
```

⚠️ **`config` is the exception — do not blind-copy it.** The two configs
deliberately differ: `pi-gen/config` carries the real `FIRST_USER_NAME`,
`FIRST_USER_PASS` and `TARGET_HOSTNAME`, while this repo's copy holds
placeholders. Apply config changes to each file individually.

Product: a Raspberry Pi appliance that boots straight into a looping mpv
playlist on bare DRM/KMS — no desktop, no login prompt. Media comes from a USB
stick; a baked-in title card plays when none is present. Built for an unattended
neighbourhood-committee event (schedule, sponsors, photo archive back to 1993).
Originally scoped as "video booth with infopanel", narrowed early to a plain
looping player — no capture, no camera. Pi 4 is the deployment target; a Pi 3 is
the test box.

## Commands

There are no tests, no linter and no build step in this repo. Verification is:
build an image, flash it, boot it, read the journal. See README Steps 1–5 for
the full walkthrough; the essentials:

```bash
# in the pi-gen clone, not here
rm stage2/EXPORT_IMAGE                 # else a second, stock "-lite" image is built
sudo ./build-docker.sh                 # 20-60 min first time; output in deploy/

# iterate on the stage only, minutes instead of a full rebuild
sudo rm -f work/pi-player-${PLAYER_BOARD:-pi4}/stage-player/SUCCESS
sudo CONTINUE=1 ./build-docker.sh
```

`WORK_DIR` is `work/${IMG_NAME}` and `IMG_NAME` carries the board tag, so each
board keeps a separate build cache — switching target cannot reuse the other
board's rootfs.

Media preparation on the workstation (`--fit blur` is the right default for a
mixed photo archive; README Step 6 has the full table):

```bash
./host-tools/prepare-media.sh --fit blur SRCDIR DSTDIR
./host-tools/prepare-media.sh --resolution 720p SRCDIR DSTDIR        # Pi 3
./host-tools/prepare-media.sh --keep-names --no-playlist SRC DST     # preserve names/order
```

Options (defaults in brackets): `-r/--resolution` (1080p; also 720p or WxH)
`-d/--duration` (5) `-f/--fit` (contain) `--fps` (30) `-c/--crf` (20)
`--preset` (medium) `--bg` (black) `--blur-sigma` (8) `--keep-names`
`--no-playlist`. Parsed with util-linux `getopt`, so long options are required
to work. **These were environment variables until 2026-09-10**; the script now
warns on stderr if a legacy name is still set rather than silently ignoring it.
Note `IMAGE_DURATION` still exists as an unrelated *device-side* setting in
`/etc/default/player` — same name, different scope.

On the booted Pi:

```bash
journalctl -u player.service -b                  # the real error; the console loop hides it
cat /run/player/playlist.m3u                     # what is actually queued
player-stats 30                                  # rss, cpu, cma_free, cache, throttling
echo '{"command":["get_property","hwdec-current"]}' | socat - /run/player/mpv.sock
```

**Ask mpv for `hwdec-current`; never grep the log for "hardware decoding".** A
fallback to software decode is completely silent.

## Architecture

Three execution contexts, easy to confuse. Every file belongs to exactly one.

### 1. Build time — `stage-player/`

pi-gen runs numbered subdirectories in order; `NN-run.sh` executes on the host
against `${ROOTFS_DIR}`, `NN-run-chroot.sh` inside the target rootfs.

- `00-install-packages/00-packages` — mpv, socat, udisks2, exfatprogs, ntfs-3g,
  dosfstools, rsync
- `01-player-files/00-run.sh` (host) — installs `files/` into the rootfs and
  applies `PLAYER_HWDEC` to `MPV_VO_OPTS`, failing the build if it doesn't take
- `01-player-files/01-run-chroot.sh` (chroot) — rewrites `User=`/`Group=` from
  `FIRST_USER_NAME`, sets `multi-user.target`, masks `getty@tty1`, disables
  logind autovt, enables `getty@tty2`, `player.service`, `player-osd-ip.timer`
  and `player-watchdog.timer`, adds the user to `video,render,input`
- `02-boot-config/00-run.sh` (host) — appends to `cmdline.txt` / `config.txt`
- `03-cleanup/00-run-chroot.sh` (chroot) — purges cloud-init, slims apt
- `EXPORT_IMAGE` carries `IMG_SUFFIX=""`, so the player image is the one
  *without* `-lite`

**`PLAYER_BOARD` in `config` is the single knob for target hardware.** It selects
`PLAYER_HWDEC` (`auto-safe` for pi4/pi5, `v4l2m2m-copy` for pi3) and sets
`IMG_NAME="pi-player-${PLAYER_BOARD}"`. An unrecognised value aborts the build.

**Architecture and Debian release come from the pi-gen git branch, not `config`.**
Setting `ARCH=`/`RELEASE=` does nothing and warns. Use `arm64`. `STAGE_LIST`
stops at `stage-player`, so desktop stages 3/4/5 never run.

Three pi-gen behaviours that make stage authoring counter-intuitive:

- **A sub-stage's `NN-packages` list is installed unconditionally.**
  `run_sub_stage` processes it independently of `NN-run.sh`, so a stage that
  exits early still installs its packages. This is why `ENABLE_CLOUD_INIT=0`
  alone leaves cloud-init installed and `03-cleanup` has to purge it.
- **`export-image` runs after your stage and partly undoes cleanup.**
  `export-image/02-set-sources/01-run.sh` deletes the apt lists and *then* runs
  `apt-get update && dist-upgrade && clean`, repopulating them into the shipped
  image (~150 MB). Config files placed in the rootfs *are* honoured by that later
  update, which is why `03-cleanup` writes `/etc/apt/apt.conf.d/99-player-slim`
  rather than relying on deleting files.
- **Custom `config` variables must be `export`ed.** pi-gen does a plain
  `source config` (build.sh:160) and sub-stage scripts run as child processes,
  so a plain assignment never reaches them and the stage silently uses its
  default.

### 2. Runtime — `stage-player/01-player-files/files/`

```
boot (multi-user.target)
  └── player.service        User=<FIRST_USER_NAME>, PAMName=login, TTYPath=/dev/tty1
        └── player-run      sources /etc/default/player
              ├── player-playlist   → /run/player/playlist.m3u + /run/player/mode
              └── mpv --gpu-context=drm --input-ipc-server=/run/player/mpv.sock

USB insert
  └── 99-usb-media.rules sets SYSTEMD_WANTS (no RUN+=)
        └── usb-media@sdX1.service    BindsTo=dev-sdX1.device
              ├── ExecStart usb-media-attach   mount ro → playlist → reload
              └── ExecStop  usb-media-detach   unmount → playlist → reload
                    └── player-reload   loadlist replace over the IPC socket

timers
  ├── player-osd-ip.timer    (30s)  hostname+IP overlay, fallback only
  └── player-watchdog.timer  (37s)  restarts a hung mpv
```

Playlist precedence in `player-playlist`:

1. `/media/usb/playlist.m3u` exists → use it, **directory scan skipped entirely**
2. USB mounted, no m3u, scan finds media → use the scan
3. USB mounted, neither → unmount, fall back to internal
4. No USB → scan `/opt/player/media` (the title card)

It also publishes the chosen mode to `/run/player/mode`, which `player-osd-ip`
reads to decide whether the fallback is on screen. `.m3u` entries resolve
relative to the stick root, so they reach arbitrary depth regardless of the
scan's `-maxdepth 2`. CRLF and `#` comments tolerated; backslash separators are
**not** translated.

`player-osd-ip` sets mpv's `osd-msg1`/`osd-level` over IPC — no re-encode, no
ffmpeg on the Pi — and clears it the moment USB content takes over.

`player-watchdog` recovers a **hung** mpv, which `Restart=always` cannot: a
stalled V4L2 decoder leaves the process running with threads in `Ssl+` and the
picture frozen, so systemd sees a healthy service. It strikes on a missing or
silent IPC socket, or on `playback-time` **and** `playlist-pos` both unchanged;
three consecutive strikes trigger `systemctl restart --no-block`. Requiring
*both* counters is deliberate — a short clip can land on the same
`playback-time` across polls, and a single-item playlist never changes position,
so either alone false-positives. The 37 s interval is deliberately not round so
a looping clip cannot alias with it. It logs `CmaFree` and `MemAvailable` when
it fires, because a restart destroys the evidence of why it hung.

`player-stats` is the diagnostic sampler (RSS, swap, %CPU over the interval,
`CmaFree`, `MemAvailable`, demuxer `fw-bytes`, SoC temperature, `hwdec-current`,
position, `vcgencmd get_throttled`, current file). Temperature prefers `vcgencmd measure_temp`
(the firmware's own SoC sensor, authoritative on a Pi) and falls back to the
thermal zone whose `type` is `cpu-thermal`. **Never assume `thermal_zone0`** —
on some kernels it is a different or stub sensor reporting a flat implausible
value (an x86 host reports `acpitz` = exactly 25000 there while the real package
sensor sits in a much higher-numbered zone). `throttled` **latches** — a
non-zero value may be from hours ago — so `temp` is the live signal and
`throttled` the history. `throttled` needs `vcgencmd`, which is present on the
built image via the pi-gen base (confirmed at `/usr/bin/vcgencmd`) rather than
anything `00-packages` adds — so do not add a package for it. It has no
fallback and reads `-` if absent; temperature does have fallbacks. `player-stats.service` is installed but
deliberately **not enabled**. **Watch `cma_free`** — it predicts a decoder
stall, and `MemAvailable` can look healthy while it is at zero. Never redirect
it to a file on the Pi: under an overlay rootfs every write is RAM.

All tunables live in `/etc/default/player`: `INTERNAL_MEDIA_DIR`,
`USB_MOUNT_DIR`, `PLAYLIST`, `MPV_SOCKET`, `IMAGE_DURATION`,
`MEDIA_EXTENSIONS`, `MPV_EXTRA_OPTS`, `SHOW_IP_ON_FALLBACK`, `WATCHDOG_STRIKES`,
`WATCHDOG_STATE`, `MODE_FILE`, `MPV_OSD_OPTS`, `MPV_VO_OPTS`.

### 3. Workstation — `host-tools/`

Never installed on the Pi. `prepare-media.sh` normalises clips *and stills* to
one canvas (`--resolution`, default 1920x1080; 720p for a Pi 3) at H.264 High
L4.1, yuv420p, SAR 1:1, no audio, fixed 2s GOP. Stills are **composited onto a
canvas**, not `pad`ded — `pad` discards alpha. Under `--fit blur` the rate
conversion happens *before* the `split`, so both branches stay frame-locked;
after the `overlay` they drift and cost a frame per clip. Files ffmpeg cannot
decode are retried through ImageMagick (`-colorspace sRGB`), which handles CMYK
JPEGs. GIFs longer than `--duration` are **truncated**.

`make-title-card.sh` renders the fallback at
`stage-player/01-player-files/files/media/000_fallback.mp4`. Text goes through
ffmpeg's `textfile=`, not `text=`; the latter breaks on apostrophes. Keep the
duration a multiple of 2.5 s or the loop seam shows.

## Non-obvious constraints

**DRM master needs a real VT *and* a logind session.** Hence `PAMName=login` +
`TTYPath=/dev/tty1`. Without both: `VT_GETMODE: Inappropriate ioctl`, then
`Failed to acquire DRM master: Permission denied`. This is why the player
**cannot be tested over SSH or with `sudo -u`** — no seat, no `XDG_RUNTIME_DIR`.
Log in on the console or use `machinectl shell`.

**No compositor, ever.** A desktop session holds DRM master and makes
`--gpu-context=drm` impossible. Hence `multi-user.target` and no getty on tty1.

**Keeping tty1 costs the other VTs, so one is bought back explicitly.**
`NAutoVTs=0` is what reliably stops logind respawning `autovt@tty1`, but it is
global — with it set, Ctrl+Alt+F2..F6 are blank. `01-run-chroot.sh` therefore
enables `getty@tty2.service`: a statically enabled getty is unaffected by
`NAutoVTs` and never touches VT1. **tty2 is the maintenance console.** Switching
to it makes mpv drop DRM master and reacquire on the way back, which is normal.

**One Pi per screen.** DRM master is exclusive per *card*, not per connector —
the Pi 4's dual HDMI is one card. Two `mpv --gpu-context=drm` processes cannot
coexist. Driving two screens from one board needs a compositor, i.e. the layer
deliberately removed.

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
renders progressive, CMYK, grayscale, 16-bit and RGBA images green or black,
with no per-format hwdec switch. Confirmed upstream in *decode*, not the display
path — it reproduces identically under `cage`/Wayland. Encoding stills as clips
removes the failure mode, gives every entry a real container duration (needed by
the multi-screen scheduler) and eliminates the mode-change flash. Consequence:
the still duration only matters for images that reach the stick *unconverted*
(`IMAGE_DURATION` in `/etc/default/player`, not the host-side `--duration`).

**The USB stick is mounted read-only** (`ro,noatime,nosuid,nodev,noexec`). It is
content, never a write target; a stick pulled mid-playback cannot leave a dirty
filesystem. `usb-media-attach` refuses any device on the boot disk.

## Bugs already fixed — do not re-derive

| Symptom | Cause | Fix |
|---|---|---|
| `libplacebo: Found no suitable device` | `gpu-next` defaults to Vulkan; VideoCore has no Vulkan driver | `--gpu-api=opengl` (in `MPV_VO_OPTS`) |
| `cannot load libcuda.so.1`, VDPAU errors | `auto-safe` probes every compiled-in backend | Cosmetic. Ignore |
| `VT_GETMODE`, `Failed to acquire DRM master` | Run from a GUI terminal / SSH — compositor holds master, no seat | Only works on bare console via the service |
| 300% CPU, RSS climbing ~55 MiB/min | `auto-safe` silently fell back to software decode on VideoCore IV | Build with `PLAYER_BOARD='pi3'`; verify via `hwdec-current` |
| `qemu-arm not found` | trixie replaced `qemu-user-static` with `qemu-user` | `apt install qemu-user qemu-user-binfmt`, `binfmt-support` **first** |
| `armhf: not supported on this machine/kernel` | binfmt handlers registered without the `F` flag | `docker run --privileged --rm tonistiigi/binfmt --install arm,arm64` |
| `E: Invalid Release signature` in stage0 | armhf-only: bundled RPi archive key uses SHA-1 | Use the `arm64` branch |
| `RELEASE does not match … this branch` | `ARCH=`/`RELEASE=` are not config variables | Removed from `config` |
| Two images in `deploy/` | `stage2/EXPORT_IMAGE` also exports | `rm stage2/EXPORT_IMAGE` |
| Boots to a login prompt, wrong hostname | Wrong SD card in the slot | Check `/etc/hostname` on the card |
| `Failed to determine user credentials`, restart loop | Unit hardcoded `User=pi`; `usermod … \|\| true` hid it at build time | `01-run-chroot.sh` rewrites it and hard-fails if the user is missing |
| `Unknown key 'StartLimitIntervalSec' in section [Service]`, service gives up after ~5 restarts | systemd moved it to `[Unit]` in v229; ignored in `[Service]`, reinstating the default limit | It now lives in `[Unit]` |
| Service `active (running)`, no picture, Main PID still `player-run`, `Tasks: 0` | `player-playlist` ran `mv` **without `-f`** over a root-owned playlist. `mv` prompts when the target is not writable and stdin is a tty — and `StandardInput=tty` hands it tty1 to block on forever | `mv -f`, and `chmod` the temp file *before* the rename |
| Player only restarts after stopping `getty@tty1`/`autovt@tty1` | logind respawns `autovt@tty1` (a separate symlink to `getty@.service`) when the player releases VT1 | `NAutoVTs=0`/`ReserveVT=0` drop-in, plus `After=getty@tty1.service` |
| `status=4/NOPERMISSION` on every stop | mpv returns 4 when it quits on a signal | `SuccessExitStatus=4` |
| Photos green / black / miscoloured | Upstream decode bug, not the display path | Convert stills to video via `prepare-media.sh` |
| GIFs lost their animation | `-loop 1` is an image2 option; the gif demuxer aborts, falling back to ImageMagick which flattens frame 0 | `-ignore_loop 0` for `.gif` |
| `XDG_RUNTIME_DIR is not set` under `sudo -u` | No login session, so `pam_systemd` never created `/run/user/<uid>` | Log in on the console, or `machinectl shell` |
| mpv RSS climbs in large steps and never returns; eventually OOM | Not a leak. mpv's demuxer read-ahead (default ~150MiB fwd + ~50MiB back) fills on long videos and never on short ones, so RSS steps to a high-water mark. Measured: +125MB per movie uncapped vs +35MB capped; peak 490MB → 246MB | Caps are now the default in `player.default`. Diagnose via `demuxer-cache-state` → `fw-bytes` |
| An OOM dump seems to show no process using memory | `rss` excludes swapped-out pages; `swapents` is where a long-running leak hides | Sum `rss + swapents` per task before concluding anything |
| `MemoryMax=` in a unit silently does nothing | Raspberry Pi OS ships `cgroup_disable=memory` on the kernel command line | Remove it from `cmdline.txt` if you need systemd memory limits |
| mpv freezes: alive, threads `Ssl+` (not `D`), IPC silent, one thread spinning | CMA exhaustion. `bcm2835-codec: dma alloc of size 3133440 failed` under `vb2_dc_alloc → v4l2_m2m_ioctl_reqbufs` — 3133440 B is one 1920x1088 NV12 frame. `CmaFree` was 120 kB of a `cma-128` pool. mpv does not fall back on a failed REQBUFS, it stalls | Keep `cma-256`. Check `CmaFree`, not `MemFree` — `MemAvailable` read 415 MB while CMA was empty |

## Conventions to preserve

- All tunables live in `/etc/default/player`; scripts source it. Never hardcode
  paths or mpv options into units or scripts.
- `player.service` ships `User=pi`; `01-run-chroot.sh` rewrites it from
  `FIRST_USER_NAME`. Keep the two in sync.
- **Build-time scripts fail loudly.** A `|| true` on `usermod` is precisely what
  shipped a broken image once. Do not add `|| true` to anything whose failure
  would produce a non-booting player.
- **Nothing run by `player.service` may prompt.** The unit sets
  `StandardInput=tty` on tty1, so any command that can ask a question blocks
  there forever with no visible error. Force `mv -f`, `rm -f`, `cp -f`.
- `player-playlist` runs as **root** from `usb-media-attach` and as the **player
  user** from `player-run`, so files in `/run/player` change owner between runs.
  Set modes on the temp file before renaming; never `chmod` after.
- `player-playlist` writes atomically and exits non-zero on an empty playlist;
  callers rely on that exit status to decide whether to revert to internal media.
- New scripts must read new variables as `${VAR:-default}` — `player-run` runs
  under `set -u`, so a bare `$NEW_VAR` aborts the player on any box whose
  `/etc/default/player` predates the change.
- Media entering the playlist must match 1920x1080@30, H.264 High L4.1,
  yuv420p, SAR 1:1, no audio, 2s GOP.

## Pi 3 vs Pi 4

Pi 4 is the deployment target; the Pi 3 is the test box. Set `PLAYER_BOARD` and
rebuild — **never hand-edit `/etc/default/player` on the card**, because the edit
dies at the next flash and the failure is silent.

- `auto-safe` on VideoCore IV falls back to software decode with no error: 300%
  CPU, RSS climbing ~55 MiB/min, OOM within the hour. `pi3` selects
  `v4l2m2m-copy`; confirm with `hwdec-current`.
- **Keep `cma-256` on both.** Earlier notes recommended `cma-128` on a 1 GB Pi 3.
  That was written while hwdec was falling back to software, where CMA sits
  unused. With hardware decode working the V4L2 decoder needs the pool and
  `cma-128` exhausts it — see the bug table.
- 1080p copy-back drops frames on a Pi 3 (memory bandwidth, not decode).
  Expected; do not tune the image around it. Use 720p test content if it
  distracts.
- Measured steady state on a Pi 3 with `v4l2m2m-copy` and the demuxer caps: RSS
  converges to ~340 MB with decaying per-movie steps (35, 32, 0, 20, 10, 6, 6,
  0, 0 MB), `swap=0`, CPU ~93% of one core.

## Open items

Discussed and code-sketched, **not applied to the stage**:

1. Recursive scan + dotfile exclusion in `player-playlist` — the scan is
   `-maxdepth 2` and deeper files are silently skipped. Dropping `-maxdepth`
   needs `-not -path '*/.*'` alongside: macOS `._` AppleDouble files decode as
   zero-length and break playback.
2. Empty-`.m3u` fallthrough to directory scan. An m3u whose entries are all
   missing yields an empty playlist and a black screen. One-line fix:
   ```bash
   usb-m3u) expand_m3u "$SOURCE" > "$TMP"; [ -s "$TMP" ] || scan_dir "$USB_MOUNT_DIR" > "$TMP" ;;
   ```
3. Flexible playlist filename. `playlist.m3u` is hardcoded and case-sensitive on
   ext4 but case-insensitive on FAT32/exFAT.
4. `hdmi_force_hotplug=1` / `hdmi_blanking=0` in `02-boot-config/00-run.sh` are
   legacy firmware settings, **inert** under `vc4-kms-v3d` — remove them. The KMS
   equivalent, worth adding if the venue display powers on after the Pi, is a
   `cmdline.txt` argument: `video=HDMI-A-1:1920x1080@60D`.
5. Verify pi-gen's own `resize` token in `cmdline.txt` survived the `tr -d '\n'`
   rewrite in `02-boot-config/00-run.sh`. If that broke first-boot filesystem
   expansion, the card silently never grows.
6. `--shuffle` currently sits in `MPV_VO_OPTS`, not `MPV_EXTRA_OPTS`. It works
   (one command line) but it is the wrong variable, and shuffle is incompatible
   with the multi-screen plan below.

Shuffle caveat: `--shuffle` shuffles once at startup, not per loop, and may not
survive a `loadlist` swap. `{"command":["playlist-shuffle"]}` is the explicit
form.

Not done, recommended before unattended running: overlay rootfs (`raspi-config`
→ Performance Options). **The overlay is not free** — its upper layer is tmpfs,
so every rootfs write consumes RAM until reboot. Cap the journal first
(`Storage=volatile`, `RuntimeMaxUse=16M`) and verify it is actually active with
`mount | grep ' / '`; `overlayroot=tmpfs` on the cmdline is not proof, the kernel
logs it as an unknown parameter. `FIRST_USER_PASS` in this repo's `config` is
still the placeholder and `ENABLE_SSH=1` uses password auth.

## Next phase: multiple screens in sync

Designed in detail, **not implemented**.

**One Pi per screen** (see Non-obvious constraints). **Do not** attempt a
master/slave design.

**Sync via shared wall clock, not a master.** Every node computes position
independently:

```
elapsed = (now - epoch) mod loop_duration
item    = entry whose [offset, offset+duration) contains elapsed
seek_to = elapsed - item.offset
```

A rebooted node rejoins mid-loop with no negotiation; the broker going down
costs control, not sync; adding a screen is plug-in-and-go.

Needs a manifest with precomputed durations (an ffprobe pass over the prepared
media — this is why stills became video):

```json
{"content_hash":"sha256:…","epoch":1757376000,"loop_duration":137.4,
 "items":[{"file":"…/001.mp4","offset":0.0,"duration":12.0}]}
```

- **Clock:** chrony, one node as local server, wired Ethernet. Sub-ms. Not PTP —
  Pi NIC hardware timestamping is inconsistent. Wi-Fi jitter would eat the budget.
- **Correction:** hard seek via `loadfile … {"start": …}` only above ~1s error;
  between 20ms and 1s nudge `speed` within ±0.2% to converge over ~10s; deadband
  below 20ms or it oscillates. Add `--video-sync=display-resample`.
- **Achievable:** ±1 frame between adjacent screens. Sub-frame genlock, no —
  independent pixel clocks, no framelock hardware. Design content so a
  bezel-spanning fast pan never happens.
- **Control plane:** MQTT (mosquitto), topics `signage/cmd/{all,node}`,
  `signage/manifest` (retained), `signage/state/<node>` (retained, last-will).
  Heartbeat carries `playlist-pos`, `playback-time`, `drift_ms`, `content_hash`
  and `vcgencmd get_throttled`.
- **Content distribution:** keep USB as the offline path. Add an rsync pull
  triggered by a manifest hash mismatch, staged then atomically renamed,
  switching at a loop boundary.
- **Shuffle is incompatible** — nodes must share a deterministic order. Shuffle
  once centrally and bake the result into the manifest.

**Build order:** (1) two Pis, chrony, same content, no sync logic — measure drift
over an hour; (2) wall-clock scheduler with hard seeks only; (3) speed correction
if the seeks are visible; (4) MQTT last. Steps 1–2 are ~150 lines of Python.

Additions needed: `player-sync.py` + `player-sync.service`
(`After=player.service`), `player-manifest`, packages `python3-paho-mqtt` and
`chrony`, and `NODE_ID` / `MQTT_BROKER` / `SYNC_EPOCH` / `SYNC_ENABLED` in
`/etc/default/player`. `player-playlist`, the udev handoff and the DRM mechanism
are unchanged.
