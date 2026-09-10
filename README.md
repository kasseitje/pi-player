# pi-player

A pi-gen appliance image for looping video + images on a Pi 3/4

Boots straight to `mpv` on bare DRM/KMS. No desktop, no login prompt, no X11 or
Wayland compositor competing for DRM master. Plug in a USB stick with media and
it takes over within a second or two; pull the stick and it falls back to
whatever was baked into the image. No reboot either way.

This is the build and operations guide. `CLAUDE.md` is the design record — why
each decision was made, the dead ends already walked, and the unfinished work.

---

## What you get

| Path (in the built image) | Purpose |
|---|---|
| `/usr/local/bin/player-run` | mpv launcher, reads `/etc/default/player` |
| `/usr/local/bin/player-playlist` | Builds the active playlist (USB > internal) |
| `/usr/local/bin/player-reload` | Hot-reloads mpv over its JSON IPC socket |
| `/usr/local/bin/usb-media-attach` | Mounts a stick read-only, rebuilds, reloads |
| `/usr/local/bin/usb-media-detach` | Unmounts, reverts to internal media, reloads |
| `/usr/local/bin/player-osd-ip` | Overlays hostname + IP on the fallback loop |
| `/usr/local/bin/player-watchdog` | Restarts the player if mpv stops responding |
| `/usr/local/bin/player-stats` | Diagnostic sampler (RSS, CPU, CMA, cache, throttling) |
| `/etc/default/player` | All tunables (image duration, VO flags, paths) |
| `/etc/systemd/system/player.service` | The player, bound to tty1 with a logind session |
| `/etc/systemd/system/usb-media@.service` | Per-device unit, lifetime bound to the stick |
| `/etc/systemd/system/player-osd-ip.timer` | Refreshes the IP overlay every 30s |
| `/etc/systemd/system/player-watchdog.timer` | Liveness poll every 37s |
| `/etc/systemd/system/player-stats.service` | Installed but **not** enabled — start it by hand |
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
your workstation: it prepares media before it ever reaches the Pi, and
monitors the box once it is running.

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
    ├── 02-boot-config/00-run.sh   (host: patches cmdline.txt + config.txt)
    └── 03-cleanup/00-run-chroot.sh (chroot: purges cloud-init, slims apt)
```

**Edit `config` before building.** At minimum change `FIRST_USER_PASS`. Set
`WPA_ESSID`/`WPA_PASSWORD` only if the unit needs Wi-Fi; a signage box that
never phones home is one less failure mode.

**Set `PLAYER_BOARD` to match the hardware.** It is the one knob for the target
board: it picks the video decoder *and* tags the image name, so a Pi 3 card can
never be confused with the Pi 4 one that goes to the venue.

```bash
PLAYER_BOARD='pi4'      # also correct for a Pi 5
PLAYER_BOARD='pi3'      # Pi 3 A+/B/B+
```

`pi3` selects `--hwdec=v4l2m2m-copy`; `pi4` selects `--hwdec=auto-safe`. Getting
this wrong on a Pi 3 is silent and expensive — see Step 8. Any custom variable
you add to `config` yourself **must be `export`ed**: pi-gen `source`s the file
and sub-stage scripts run as child processes, so a plain assignment never
reaches them.

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

Output lands in `deploy/` as `image_<date>-pi-player-<board>.img.xz`, where
`<board>` is `PLAYER_BOARD` from `config` (`pi4` or `pi3`).

Resuming after a failure: pi-gen caches completed stages. `sudo CONTINUE=1
./build-docker.sh` picks up where it left off. If you changed anything in
`stage-player`, delete its marker first so it re-runs:

```bash
sudo rm -f work/pi-player-${PLAYER_BOARD:-pi4}/stage-player/SUCCESS
sudo CONTINUE=1 ./build-docker.sh
```

For a genuinely clean rebuild: `sudo rm -rf work deploy`.

---

## Step 5 — Flash

```bash
xz -d deploy/image_*-pi-player-*.img.xz     # check which board you picked
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
uniform, audio-free H.264 at one resolution, and writes a `playlist.m3u`:

```bash
./host-tools/prepare-media.sh ~/raw-media /media/MY-USB-STICK
./host-tools/prepare-media.sh --resolution 720p --fit blur ~/raw-media /media/STICK
./host-tools/prepare-media.sh -d 8 -c 22 ~/raw-media /media/STICK
./host-tools/prepare-media.sh --help
```

**`--resolution` is the setting that has to match the board.** 1080p is the
default and is right for a Pi 4. A Pi 3 cannot sustain it through the
`v4l2m2m-copy` path: over an 8.5-hour soak every long clip stayed on screen for
~1.78× its real duration — a 28-minute clip occupying 51 minutes of the loop —
with `cma_free` touching 0 MB. CPU sat at ~90% of one core and `hwdec-current`
stayed `v4l2m2m-copy` throughout, so this is memory bandwidth in the copy-back
path, not a decode fallback. `--resolution 720p` halves that bandwidth and
halves the CMA cost per frame (1.4 MB vs 3.0 MB), which addresses both at once.

**Stills are converted to 5-second video clips, not copied through.** Decoding
stills via mpv's V4L2/GL path on a Pi produces green or black frames for
progressive, CMYK, grayscale, 16-bit and alpha images, and mpv has no per-format
hwdec switch to work around it. Encoding them as video removes that failure mode
outright. It also gives every playlist entry a real container duration, which
the multi-screen scheduler needs, and lets you set per-image durations by
re-running with a different `--duration`.

Uniformity matters more than it sounds: mismatched resolutions or frame rates
between playlist items cause a visible mode-change flash on the display each
time mpv advances. Check a folder before trusting it — resolution alone is not
enough, `level` and `r_frame_rate` differ between a camera clip and a prepared
still even at the same size:

```bash
find ~/raw-media -name '*.mp4' -print0 | while IFS= read -r -d '' f; do
  ffprobe -v error -select_streams v:0 -show_entries \
    stream=codec_name,profile,level,width,height,pix_fmt,r_frame_rate,sample_aspect_ratio,field_order,refs,has_b_frames \
    -of csv=p=0 "$f"
done | sort | uniq -c | sort -rn
```

One line out means uniform. More than one means the odd files need re-running
through `prepare-media.sh`.

**`--fit` controls what happens to anything that is not 16:9** — which is most of
a photo archive:

| `--fit` | Result |
|---|---|
| `contain` (default) | fits inside, `--bg` bars baked into the frame — nothing lost, but a portrait photo is mostly black bar |
| `cover` | fills the screen, crops the overflow — **edges are lost**, brutal on portrait |
| `blur` | blurred zoomed copy of the image fills the screen, uncropped image on top — no bars, nothing lost |

```bash
./host-tools/prepare-media.sh --fit blur ~/raw-media /media/MY-USB-STICK
```

`blur` is the right default for a mixed archive going back to 1993: portrait
phone shots and scanned 4:3 prints keep every pixel, and the screen still fills.
Use `cover` only if you know the content is all landscape and you accept losing
the edges.

Animated GIFs keep their animation, repeated to fill `--duration`. (GIF
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

Confirm hardware decode is actually live — ask mpv rather than grepping logs,
because a fallback to software is silent:

```bash
echo '{"command":["get_property","hwdec-current"]}' | socat - /run/player/mpv.sock
```

Watch the box's health over time. `cma_free` is the number that predicts a
decoder stall; `cpu` around one core (~90%) means hardware decode is working,
~300% means it is not; `temp` warns before `throttled` ever trips (soft throttle
starts at 80 C, hard at 85 C):

```bash
player-stats 30                 # one line every 30s, Ctrl-C to stop
player-stats --once             # single sample
sudo systemctl start player-stats && journalctl -fu player-stats
```

Never redirect `player-stats` to a file on the Pi itself — with an overlay
rootfs every write is RAM. Pipe it over SSH, or use the journal, which is
size-capped.

**Piping the stats to your workstation.** `player-stats` writes plain lines to
stdout and reads nothing from stdin, so SSH is the entire mechanism — the log
file lives on your machine and the appliance writes nothing at all:

```bash
ssh pi@pi-player.local player-stats 30 | tee ~/pi-player-$(date +%F).log
```

`tee` so you watch it live *and* keep the file; use `>` alone if you only want
the file. `pi-player.local` needs mDNS on your network — if it doesn't resolve,
use the IP `player-osd-ip` overlays on the fallback loop.

Add `-t` if you want Ctrl-C to stop the sampler immediately. Without a tty the
remote process only notices the dead pipe on its *next* write, so it keeps
sampling for up to one interval after you disconnect. The cost of `-t` is CRLF
line endings, which is one `tr` away:

```bash
ssh -t pi@pi-player.local player-stats 30 | tr -d '\r' | tee ~/stats.log
```

For an overnight soak, keep the connection from being culled by whatever NAT
sits between you and the venue, and reconnect if it dies anyway:

```bash
while :; do
  ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10 \
      pi@pi-player.local player-stats 30
  echo "# reconnected $(date -Is)"
  sleep 5
done | tee -a ~/pi-player-soak.log
```

`tee -a` is load-bearing: every reconnect re-enters the loop, and a plain `>`
would truncate everything collected so far. Use a key, not a password — the loop
will otherwise stop and wait for one at 03:00. The `#` marker lines make gaps in
the record obvious afterwards; nothing downstream chokes on them.

If `player-stats.service` is already running on the box, tail the journal
instead — same lines, and the sampler survives your laptop closing:

```bash
ssh pi@pi-player.local 'journalctl -fu player-stats --output=cat' | tee ~/stats.log
```

`--output=cat` drops the syslog prefix so the lines match the ones above. Add
`--since=-2h` to pull in what was already collected before you connected.

**A live dashboard instead of a wall of text.** `host-tools/player-monitor.py`
takes the same feed on stdin and repaints a btop-style screen: one bordered box
per metric, each with a multi-row area graph coloured by value. Python stdlib
only, nothing to install, and nothing runs on the Pi that wasn't already
running:

```bash
ssh pi@pi-player.local player-stats 30 | ./host-tools/player-monitor.py
ssh pi@pi-player.local player-stats 30 | ./host-tools/player-monitor.py --log soak.log
ssh pi@pi-player.local player-stats 30 | ./host-tools/player-monitor.py --braille
```

```
╭─ pi-player ───────────────────────────────────────── 03:00:09 · 399 samples · 3h26m ─╮
│ hwdec     v4l2m2m-copy                                                               │
│ throttled 0x0                                                                        │
│ file      1993_optreden-na.mp4                                                       │
╰──────────────────────────────────────────────────────────────────────────────────────╯
╭─ rss ───────────────────────────────────────────────────────────────────────── 374M ─╮
│                                                       ▂▃▃█                           │
│                                                      ▄████                           │
│ ▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂▂█████▇              ▁▂▂▂▂▂▂▂▂▂▂ │
╰─ start 140M  peak 418M  Δ +234M  +68M/h ─────────────────────────────────────────────╯
╭─ cma free ───────────────────────────────────────────────────────────────────── 64M ─╮
│ ▆▅ ▂▆▆▄▅▁▃▆▃█▂▆▅▄▆▆▅▃▆▃▂▇▂▅▃▂ ▇▆█▅▅▇▅▇▄▅█▅▆▄▃▆▆▄▅▄▁▇▄▅▅█▆▆   ▂▁▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄ │
│ ██▇███████████████████████████████████████████████████████▁  ███████████████████████ │
│ ███████████████████████████████████████████████████████████ ▅▂██████████████████████ │
╰─ start 121M  peak 122M  Δ -57M  -17M/h ──────────────────────────────────────────────╯
```

Graphs are coloured green→red by where each sample sits in that metric's own
range, and inverted for `cma free` and `mem avail` where *low* is the bad end.
Boxes and graph height adapt to the window: on a short terminal the graphs
shrink to one row and the least interesting metrics (`pos`, `cache`, `swap`)
drop off the bottom first. `--rows N` forces a height, and `--braille` packs two
samples into every column for twice the visible history — it needs a font with
braille coverage, which most terminal fonts have.

The `+68M/h` on `rss` is the number to read first — it is what separates
warm-up from a leak, and it needs two minutes of run before it appears at all.
`cma free` goes red below 64 MB and `temp` red at 80 C, and the screen grows a
line per condition when something is actually wrong:

```
  ! cma_free 31M - decoder stall territory; a frozen picture with the service still 'active' looks like this
  ! hwdec=no - software decode; expect ~300% cpu, RSS climbing and an OOM kill within the hour
  ! throttled=0x50005 - it has throttled at some point (the flag latches, so this may be hours old)
  ! 1 sample(s) with mpv not running - it restarted
```

Ctrl-C prints a first/last/min/max/rate summary for every metric — the same
summary you get piping a saved log back through it with `--plain`:

```bash
./host-tools/player-monitor.py --plain < soak.log
```

Fields are read by name, so a sampler that grows a field displays it without
edits here; `swap` hides itself while it is flat zero and reappears the moment
it isn't. Metrics the kernel doesn't expose arrive as `-` and are skipped rather
than plotted as `0` — on a non-Pi kernel `CmaFree` is absent, and `0` would be a
very different and much more alarming answer.

**Reading the log back.** The worst CMA reading over the whole run is the number
that predicts a decoder stall, and it is one pipeline away:

```bash
grep -o 'cma_free=[0-9]*' ~/pi-player-soak.log | cut -d= -f2 | sort -n | head -1
```

For a plot, the `key=value` format turns into CSV without any parsing library
(timestamp, RSS, CPU, CMA free, temperature):

```bash
sed -n 's/^\(.\{19\}\) .*rss=\([0-9]*\)M.* cpu=\([0-9]*\)%.* cma_free=\([0-9-]*\)M.* temp=\([0-9.-]*\)C.*/\1,\2,\3,\4,\5/p' \
  ~/pi-player-soak.log
```

Lines where mpv was not running have no fields to match and drop out — count
them separately with `grep -c 'mpv not running'`, because that is the watchdog
having restarted the player and it matters more than any of the numbers.

For an unattended one-shot from your own cron, `--once` exits after a single
sample:

```bash
ssh pi@pi-player.local player-stats --once >> ~/pi-player-hourly.log
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
MEDIA_EXTENSIONS="mp4 jpg png"       # narrow what counts as media
SHOW_IP_ON_FALLBACK="0"              # hide the hostname/IP overlay
WATCHDOG_STRIKES="0"                 # disable the hang watchdog
```

**Do not empty `MPV_EXTRA_OPTS`.** It ships with demuxer caps that are load-
bearing on a memory-constrained board:

```bash
MPV_EXTRA_OPTS="--demuxer-max-bytes=32MiB --demuxer-max-back-bytes=8MiB"
```

mpv reads ahead until its packet queue is full. A 5-second still-turned-clip
never fills it; a multi-minute video does, and the ~150 MiB default lands as a
single step in RSS that never comes back — on a 1 GB Pi 3 that was the
difference between a 490 MB peak and a 246 MB one. Add `--shuffle` here if you
want it; don't replace the line.

If you ever see the libplacebo `Found no suitable device` error (Vulkan probing,
which VideoCore never satisfies on older boards), `MPV_VO_OPTS` already pins
`--gpu-api=opengl` to skip it.

**Testing on a Pi 3?** Set `PLAYER_BOARD='pi3'` in `config` and rebuild — do not
hand-edit `/etc/default/player`, because that edit dies at the next flash and the
failure is completely silent. `--hwdec=auto-safe` falls back to *software* decode
on VideoCore IV: 300% CPU, RSS climbing ~55 MiB/min, and an OOM kill within the
hour. Nothing logs an error. Confirm which path is live with:

```bash
echo '{"command":["get_property","hwdec-current"]}' | socat - /run/player/mpv.sock
```

`"v4l2m2m-copy"` is correct; `"no"` means it fell back.

**Leave `cma-256` alone.** Earlier versions of this guide suggested dropping to
`cma-128` on a Pi 3 to free general RAM. That advice was written while hwdec was
silently falling back to software, where CMA sits unused. With hardware decode
actually working the V4L2 decoder needs that pool, and `cma-128` exhausts it:

```
bcm2835-codec bcm2835-codec: dma alloc of size 3133440 failed
```

mpv does not error or fall back on that — it just **hangs**, with the picture
frozen and its threads still in `Ssl+`. Watch `CmaFree` in `/proc/meminfo`, not
`MemFree`: `MemAvailable` can read a healthy 400 MB while CMA is at 120 kB.

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

**The overlay is not free.** Its upper layer is tmpfs, so every write to the
rootfs consumes RAM and is never reclaimed until reboot. Cap the journal before
enabling it on a 1 GB board, and confirm nothing else writes to `/`:

```bash
printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' \
  | sudo tee /etc/systemd/journald.conf.d/10-player.conf
sudo du -xh --max-depth=2 /var | sort -h | tail -20
```

Also verify it actually took — `overlayroot=tmpfs` on the kernel command line is
*not* proof, the kernel logs it as an unknown parameter and something in
userspace has to act on it:

```bash
mount | grep ' / '        # "overlay" = active, "ext4" = not
```

**A hung player recovers by itself.** `player-watchdog.timer` polls mpv every
37 s and restarts the service after three consecutive failures — either a silent
IPC socket, or `playback-time` and `playlist-pos` both frozen. This matters
because `Restart=always` only catches a process that *exits*: a stalled V4L2
decoder leaves mpv running with the screen frozen, and systemd sees a perfectly
healthy service. Set `WATCHDOG_STRIKES=0` to disable it while debugging, so a
stall is preserved for inspection instead of being restarted away.

**The maintenance console is tty2**, not tty1. tty1 belongs to the player and
`NAutoVTs=0` stops logind spawning gettys anywhere, so Ctrl+Alt+F2 is the login
prompt and F3–F6 are deliberately blank.

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
| Picture frozen, service reports `active (running)` | mpv hung, not crashed — usually a CMA allocation failure in the V4L2 decoder | `journalctl -k -b \| grep bcm2835-codec`; check `CmaFree` in `/proc/meminfo`; restore `cma-256`. The watchdog restarts it after ~2 min |
| mpv killed by the OOM killer | Read `swapents`, not `rss`, in the OOM dump — a paged-out process looks tiny | Confirm `hwdec-current` is not `"no"`, and that `MPV_EXTRA_OPTS` still has the demuxer caps |
| Ctrl+Alt+F2 gives a blank console | `NAutoVTs=0` stops logind spawning gettys | tty2 has a static getty; F3–F6 are blank by design. `systemctl enable --now getty@tty3` if you want another |
| 300% CPU and RSS climbing fast | `--hwdec=auto-safe` fell back to software decode | Rebuild with `PLAYER_BOARD='pi3'`; verify with `hwdec-current` |
| Service dies for good after a few restarts | `StartLimitIntervalSec` must live in `[Unit]` — systemd ignores it in `[Service]` and reinstates the default 5-starts-in-10s limit | Already fixed in the shipped unit; check `systemctl cat player.service` if you edited it |

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

**Why there is a watchdog at all.** `Restart=always` is not a liveness check —
it only catches a process that *exits*. Every genuinely bad failure seen on this
hardware left mpv *running*: a failed video buffer allocation leaves it stalled
with the picture frozen, and systemd reports the service as perfectly healthy.
`player-watchdog` polls mpv instead and restarts it after three strikes.

**Why nothing the service runs may prompt.** `player.service` gives mpv tty1 as
its standard input, so any command that asks a question blocks there forever
with no visible error and the player never starts. Anything the service calls
must use `mv -f`, `rm -f`, `cp -f`.

Full rationale for these, plus the bugs already found and fixed, is in
`CLAUDE.md`.
