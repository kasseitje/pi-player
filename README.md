# pi-player — a pi-gen appliance image for looping video + images on a Pi 4

Boots straight to `mpv` on bare DRM/KMS. No desktop, no login prompt, no X11 or
Wayland compositor competing for DRM master. Plug in a USB stick with media and
it takes over within a second or two; pull the stick and it falls back to
whatever was baked into the image. No reboot either way.

---

## What you get

| Path (in the built image) | Purpose |
|---|---|
| `/usr/local/bin/player-run` | mpv launcher, reads `/etc/default/player` |
| `/usr/local/bin/player-playlist` | Builds the active playlist (USB > internal) |
| `/usr/local/bin/player-reload` | Hot-reloads mpv over its JSON IPC socket |
| `/usr/local/bin/usb-media-attach` | Mounts a stick read-only, rebuilds, reloads |
| `/usr/local/bin/usb-media-detach` | Unmounts, reverts to internal media, reloads |
| `/etc/default/player` | All tunables (image duration, VO flags, paths) |
| `/etc/systemd/system/player.service` | The player, bound to tty1 with a logind session |
| `/etc/systemd/system/usb-media@.service` | Per-device unit, lifetime bound to the stick |
| `/etc/udev/rules.d/99-usb-media.rules` | Hands USB filesystems to the unit above |
| `/opt/player/media/` | Baked-in fallback media |
| `/media/usb/` | Mount point for the stick |

---

## Step 1 — Build host prerequisites

pi-gen needs Linux. On a managed Windows box, WSL2 with Docker Desktop works;
otherwise any Debian/Ubuntu machine or VM.

```bash
sudo apt install -y docker.io git
sudo usermod -aG docker "$USER"     # log out and back in

# binfmt-support FIRST: the qemu package registers its handlers in a postinst
# hook and silently does nothing if binfmt-support is not already present.
sudo apt install -y binfmt-support
sudo apt install -y qemu-user qemu-user-binfmt
```

Current pi-gen looks for the `qemu-arm` binary, not `qemu-arm-static` — Debian
trixie replaced `qemu-user-static` with `qemu-user`. Installing the old package
gives you "qemu-arm not found (please install qemu-user-binfmt)".

Verify the handlers landed, and that they carry the `F` (fix-binary) flag —
without `F` the interpreter path is resolved inside the container's mount
namespace, where it does not exist:

```bash
grep -E 'enabled|interpreter|flags' /proc/sys/fs/binfmt_misc/qemu-aarch64
```

If `flags:` has no `F`, re-register them:

```bash
docker run --privileged --rm tonistiigi/binfmt --uninstall 'qemu-*'
docker run --privileged --rm tonistiigi/binfmt --install arm,arm64
```

These registrations are lost on reboot.

If you build **arm64 on an x86 host**, the container needs binfmt handlers
registered on the host kernel. `build-docker.sh` normally handles this, but if
the build dies inside the chroot with `exec format error`:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Budget roughly 20–40 GB of free disk and 20–60 minutes for a first build.

---

## Step 2 — Clone pi-gen and drop this scaffold in

**Architecture and Debian release are selected by git branch, not by config
variables.** 32-bit images build from `master`, 64-bit from `arm64`. Setting
`ARCH=` or `RELEASE=` in `config` does nothing and triggers a
"RELEASE does not match the intended option for this branch" warning.

Use `arm64` — it covers Pi 3, 4 and 5, and it also sidesteps a known armhf-only
bug where the bundled Raspberry Pi archive key uses SHA-1 signatures that modern
GnuPG rejects, failing stage0 with `E: Invalid Release signature`.

```bash
git clone --depth 1 https://github.com/RPi-Distro/pi-gen.git
cd pi-gen
git fetch --depth 1 origin arm64
git checkout -B arm64 FETCH_HEAD

# from this scaffold — ONLY these two go into the pi-gen clone:
cp -r /path/to/pi-player/stage-player  ./stage-player
cp    /path/to/pi-player/config        ./config
```

`README.md` and `host-tools/` are **not** part of the build. Keep them wherever
you unpacked the scaffold; copying them into the pi-gen clone just adds
untracked files to a git repo you will later want to pull. `host-tools/` runs on
your workstation to prepare media before it ever reaches the Pi.

Your tree should now look like:

```
pi-gen/
├── build.sh
├── build-docker.sh
├── config                ← yours
├── stage0/ stage1/ stage2/ stage3/ stage4/ stage5/
└── stage-player/         ← yours
    ├── prerun.sh
    ├── EXPORT_IMAGE
    ├── 00-install-packages/00-packages
    ├── 01-player-files/
    │   ├── 00-run.sh              (host: installs files into the rootfs)
    │   ├── 01-run-chroot.sh       (chroot: enables units, sets boot target)
    │   └── files/…
    └── 02-boot-config/00-run.sh   (host: patches cmdline.txt + config.txt)
```

**Edit `config` before building.** At minimum change `FIRST_USER_PASS`. Set
`WPA_ESSID`/`WPA_PASSWORD` only if the unit needs Wi-Fi; a signage box that
never phones home is one less failure mode.

`STAGE_LIST='stage0 stage1 stage2 stage-player'` means the desktop stages
(3/4/5) never run — no SKIP files needed.

**Delete `stage2/EXPORT_IMAGE`.** stage2 still has to *run* (your stage copies
its rootfs), but its own `EXPORT_IMAGE` makes it emit a second, stock Lite image
you do not want — and which is easy to flash by mistake:

```bash
rm stage2/EXPORT_IMAGE
```

Exporting is not cheap: it allocates a file, formats partitions, rsyncs the
rootfs and xz-compresses it. Dropping it saves several minutes per build.
The file is tracked by git, so `git update-index --skip-worktree
stage2/EXPORT_IMAGE` keeps a future `git pull` from restoring it.

If you do build both, the player image is the one **without** the `-lite`
suffix — that comes from `stage2/EXPORT_IMAGE`'s `IMG_SUFFIX="-lite"`.

---

## Step 3 — Bake in fallback media (optional)

Anything you drop here ends up in `/opt/player/media` and plays whenever no USB
stick is present. Good for a "insert your USB stick" title card, or the default
loop if the stick walks off.

```bash
mkdir -p stage-player/01-player-files/files/media
cp ~/clips/fallback.mp4 stage-player/01-player-files/files/media/
```

A title card is already baked in at `files/media/000_fallback.mp4`. To re-render
it with different text or a different logo:

```bash
./host-tools/make-title-card.sh out.mp4 host-tools/kasseitje-logo-plate.png \
  "Steek je USB-stick in" \
  "FAT32 of exFAT — video's en foto's in de hoofdmap" \
  "GEEN MEDIA GEVONDEN" "Afspelen start automatisch"
```

Pass `""` for the logo to render without one. Keep the duration a multiple of
2.5s — the eyebrow pulses on that period and any other length makes the loop
seam visible.

With nothing here the player idles on a black screen until a stick appears —
functional, but a title card is friendlier when something goes wrong at the
venue.

---

## Step 4 — Build

```bash
sudo ./build-docker.sh
```

Output lands in `deploy/` as `image_<date>-pi-player.img.xz`.

Resuming after a failure: pi-gen caches completed stages. `sudo CONTINUE=1
./build-docker.sh` picks up where it left off. If you changed anything in
`stage-player`, delete its marker first so it re-runs:

```bash
sudo rm -f work/pi-player/stage-player/SUCCESS
sudo CONTINUE=1 ./build-docker.sh
```

For a genuinely clean rebuild: `sudo rm -rf work deploy`.

---

## Step 5 — Flash

```bash
xz -d deploy/image_*-pi-player.img.xz
sudo rpi-imager                    # "Use custom" → select the .img
```

Don't apply Imager's OS-customisation settings on top — hostname, user, SSH,
locale and Wi-Fi are already baked in by `config`, and Imager's `firstrun.sh`
can fight the boot-target and user setup.

---

## Step 6 — Prepare the USB stick

Format as FAT32 or exFAT (both handled; `exfatprogs` and `ntfs-3g` are in the
image). Then either:

**A. Drop files in and let it sort** — playback follows filename order, so use
numeric prefixes:

```
001_intro.mp4
002_sponsors.jpg
003_bloementapijt.mp4
```

**B. Control order explicitly** — put a `playlist.m3u` in the stick's root.
Relative paths resolve against the stick; absolute paths work too; `#` lines and
CRLF endings are tolerated; entries pointing at files that don't exist are
dropped with a log line rather than breaking playback.

`host-tools/prepare-media.sh` normalises everything — clips *and* stills — to
uniform 1080p30 H.264 with audio stripped, and writes a `playlist.m3u`:

```bash
./host-tools/prepare-media.sh ~/raw-media /media/MY-USB-STICK
IMAGE_DURATION=8 CRF=22 ./host-tools/prepare-media.sh ~/raw-media /media/STICK
```

**Stills are converted to 5-second video clips, not copied through.** Decoding
stills via mpv's V4L2/GL path on a Pi produces green or black frames for
progressive, CMYK, grayscale, 16-bit and alpha images, and mpv has no per-format
hwdec switch to work around it. Encoding them as video removes that failure mode
outright. It also gives every playlist entry a real container duration, which
the multi-screen scheduler needs, and lets you set per-image durations by
re-running with a different `IMAGE_DURATION`.

Uniformity matters more than it sounds: mismatched resolutions or frame rates
between playlist items cause a visible mode-change flash on the display each
time mpv advances.

Animated GIFs keep their animation, repeated to fill `IMAGE_DURATION`. (GIF
needs `-ignore_loop 0` rather than `-loop 1` — the latter is an image2 demuxer
option and aborts on a `.gif`.)

Files that ffmpeg cannot decode are retried through ImageMagick (`sudo apt
install imagemagick`), which handles CMYK JPEGs and odd PNG bit depths. Anything
still failing is listed at the end and the script exits non-zero — nothing is
silently dropped from the loop.

---

## Step 7 — First boot and verification

Power on with a display attached. You should see kernel messages briefly, then
playback. No login prompt, no desktop.

SSH in to check:

```bash
systemctl status player.service
journalctl -u player.service -b
cat /run/player/playlist.m3u          # what is actually queued
```

Plug in a stick and watch it get picked up:

```bash
journalctl -f -t usb-media-attach -t player-playlist -t player-reload
```

Confirm hardware decode is live (Pi 4 should manage 1080p without breaking a
sweat, unlike the Pi 3):

```bash
journalctl -u player.service -b | grep -i "hardware decoding"
```

Poke mpv directly over IPC:

```bash
echo '{"command":["get_property","playlist-pos"]}' | socat - /run/player/mpv.sock
echo '{"command":["get_property","filename"]}'     | socat - /run/player/mpv.sock
```

---

## Step 8 — Tuning

Everything lives in `/etc/default/player`; `systemctl restart player.service`
to apply.

```bash
IMAGE_DURATION="12"                  # seconds per still
MPV_EXTRA_OPTS="--shuffle"           # randomise order
MEDIA_EXTENSIONS="mp4 jpg png"       # narrow what counts as media
```

If you ever see the libplacebo `Found no suitable device` error (Vulkan probing,
which VideoCore never satisfies on older boards), `MPV_VO_OPTS` already pins
`--gpu-api=opengl` to skip it.

**Testing on a Pi 3?** The arm64 image boots there unchanged, but two defaults
are Pi 4 assumptions. `--hwdec=auto-safe` silently falls back to software decode
on VideoCore IV (300% CPU), so pin it:

```bash
MPV_VO_OPTS="--vo=gpu --gpu-api=opengl --gpu-context=drm --hwdec=v4l2m2m-copy"
```

And `cma-256` in `config.txt` is generous against a Pi 3's fixed 1 GB — drop it
to `cma-128`. Neither change is needed on a Pi 4.

---

## Step 9 — Harden for unattended running

Strongly recommended before the unit sits somewhere for a day. Run on the
booted Pi:

```bash
sudo raspi-config           # Performance Options → Overlay File System → enable
```

The rootfs becomes read-only with a RAM overlay, so yanking power can't corrupt
the SD card. The USB stick is already mounted read-only by
`usb-media-attach`, so pulling that mid-playback is safe too. Remember to
disable the overlay temporarily whenever you want to change baked-in media or
config.

Worth checking on-site before the event:

```bash
vcgencmd measure_temp
vcgencmd get_throttled       # non-zero = it has been throttling
```

A Pi 4 in a sealed enclosure decoding 1080p for hours in the sun will throttle,
and that shows up as dropped frames rather than an error message.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to determine user credentials: No such process` | `FIRST_USER_NAME` != `User=` in the unit | `01-run-chroot.sh` rewrites this; if you edited the unit by hand, match the two |
| Repeated "Started player.service" on console | mpv exiting; `Restart=always` retries forever | `journalctl -u player.service -b` — the loop hides the real error |
| Hostname/user not what `config` says | rpi-imager applied a saved customisation profile | Check for `/boot/firmware/firstrun.sh`; choose "No, clear settings" when flashing |
| `VT_GETMODE: Inappropriate ioctl` | Not on a real VT | `TTYPath`/`PAMName=login` — already in the unit; check nothing else grabbed tty1 |
| `Failed to acquire DRM master: Permission denied` | A compositor holds it, or no seat | `systemctl get-default` must be `multi-user.target`; `loginctl list-sessions` should show seat0 on tty1 |
| Black screen, service running | Empty playlist | `cat /run/player/playlist.m3u`; check `journalctl -t player-playlist` |
| Stick ignored | No filesystem signature, or it's on the boot disk | `lsblk -f`; the attach script deliberately skips the boot disk |
| Screen blanks after minutes | `consoleblank` | Confirm `consoleblank=0` survived in `/boot/firmware/cmdline.txt` |
| Playlist doesn't update on insert | udev → systemd handoff | `udevadm monitor --property` while inserting; `systemctl status 'usb-media@*'` |

---

## Design notes

**Why a systemd template unit instead of `RUN+=` in the udev rule.** udev kills
`RUN+=` processes after a short timeout and runs them in a restricted context —
mounting, scanning and talking to mpv all exceed that. The rule only sets
`SYSTEMD_WANTS`; systemd owns the actual work. `BindsTo=dev-%i.device` means
removal stops the unit, which runs `ExecStop` — so unplug handling is free
rather than a second udev rule that races the first.

**Why IPC reload instead of restarting mpv.** A fresh mpv has to re-open
`/dev/dri/card0`, re-negotiate the mode and re-init the GL context: a second or
more of black screen. `loadlist … replace` reuses the open display session, so
the swap costs one frame. It also sidesteps the classic `pkill mpv; mpv …` race
where the DRM device node hasn't been released before the new process grabs it.
`player-reload` falls back to a `--no-block` service restart if the socket is
unreachable.

**Why the USB stick is mounted read-only.** It's content, never a write target.
Read-only means a stick pulled mid-playback can't leave a dirty filesystem, and
pairs with the overlay rootfs so the whole appliance survives arbitrary power
loss.
