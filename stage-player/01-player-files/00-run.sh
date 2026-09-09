#!/bin/bash -e

# Executable helpers
install -v -m 755 -o root -g root files/bin/player-run        "${ROOTFS_DIR}/usr/local/bin/player-run"
install -v -m 755 -o root -g root files/bin/player-playlist   "${ROOTFS_DIR}/usr/local/bin/player-playlist"
install -v -m 755 -o root -g root files/bin/player-reload     "${ROOTFS_DIR}/usr/local/bin/player-reload"
install -v -m 755 -o root -g root files/bin/usb-media-attach  "${ROOTFS_DIR}/usr/local/bin/usb-media-attach"
install -v -m 755 -o root -g root files/bin/usb-media-detach  "${ROOTFS_DIR}/usr/local/bin/usb-media-detach"
install -v -m 755 -o root -g root files/bin/player-osd-ip     "${ROOTFS_DIR}/usr/local/bin/player-osd-ip"
install -v -m 755 -o root -g root files/bin/player-watchdog   "${ROOTFS_DIR}/usr/local/bin/player-watchdog"
install -v -m 755 -o root -g root files/bin/player-stats      "${ROOTFS_DIR}/usr/local/bin/player-stats"

# Tunables
install -v -m 644 -o root -g root files/etc/player.default    "${ROOTFS_DIR}/etc/default/player"

# Hardware decoding is a build-time choice because there is no runtime probe
# that gets it right. --hwdec=auto-safe picks the good path on a Pi 4, but on a
# Pi 3's VideoCore IV it silently falls back to SOFTWARE decode: 300% CPU, and
# RSS climbing until the OOM killer takes mpv out. Nothing logs an error.
PLAYER_HWDEC="${PLAYER_HWDEC:-auto-safe}"
sed -i "s/--hwdec=[^ \"]*/--hwdec=${PLAYER_HWDEC}/" "${ROOTFS_DIR}/etc/default/player"

# Fail the build rather than shipping an image that silently software-decodes.
if ! grep -q -- "--hwdec=${PLAYER_HWDEC}" "${ROOTFS_DIR}/etc/default/player"; then
	echo "FATAL: could not set --hwdec=${PLAYER_HWDEC} in /etc/default/player"
	exit 1
fi
echo "player: hwdec=${PLAYER_HWDEC}"

# systemd units
install -v -m 644 -o root -g root files/systemd/player.service     "${ROOTFS_DIR}/etc/systemd/system/player.service"
install -v -m 644 -o root -g root files/systemd/usb-media@.service "${ROOTFS_DIR}/etc/systemd/system/usb-media@.service"
install -v -m 644 -o root -g root files/systemd/player-osd-ip.service "${ROOTFS_DIR}/etc/systemd/system/player-osd-ip.service"
install -v -m 644 -o root -g root files/systemd/player-osd-ip.timer   "${ROOTFS_DIR}/etc/systemd/system/player-osd-ip.timer"
install -v -m 644 -o root -g root files/systemd/player-watchdog.service "${ROOTFS_DIR}/etc/systemd/system/player-watchdog.service"
install -v -m 644 -o root -g root files/systemd/player-watchdog.timer   "${ROOTFS_DIR}/etc/systemd/system/player-watchdog.timer"
# Diagnostic only - deliberately NOT enabled in 01-run-chroot.sh. Start it by
# hand when investigating something: systemctl start player-stats
install -v -m 644 -o root -g root files/systemd/player-stats.service    "${ROOTFS_DIR}/etc/systemd/system/player-stats.service"

# udev rule
install -v -m 644 -o root -g root files/udev/99-usb-media.rules "${ROOTFS_DIR}/etc/udev/rules.d/99-usb-media.rules"

# Media directories
install -v -d -m 755 -o root -g root "${ROOTFS_DIR}/opt/player/media"
install -v -d -m 755 -o root -g root "${ROOTFS_DIR}/media/usb"

# Drop any fallback media you want baked into the image here.
if [ -d files/media ] && [ -n "$(ls -A files/media 2>/dev/null)" ]; then
	cp -v files/media/* "${ROOTFS_DIR}/opt/player/media/"
fi

# A visible marker so a freshly flashed card with no USB stick shows *something*
# rather than a black screen.
if [ ! -n "$(ls -A "${ROOTFS_DIR}/opt/player/media" 2>/dev/null)" ]; then
	echo "no baked-in media; player will idle until a USB stick is inserted"
fi
