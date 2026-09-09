#!/bin/bash -e

# Executable helpers
install -v -m 755 -o root -g root files/bin/player-run        "${ROOTFS_DIR}/usr/local/bin/player-run"
install -v -m 755 -o root -g root files/bin/player-playlist   "${ROOTFS_DIR}/usr/local/bin/player-playlist"
install -v -m 755 -o root -g root files/bin/player-reload     "${ROOTFS_DIR}/usr/local/bin/player-reload"
install -v -m 755 -o root -g root files/bin/usb-media-attach  "${ROOTFS_DIR}/usr/local/bin/usb-media-attach"
install -v -m 755 -o root -g root files/bin/usb-media-detach  "${ROOTFS_DIR}/usr/local/bin/usb-media-detach"
install -v -m 755 -o root -g root files/bin/player-osd-ip     "${ROOTFS_DIR}/usr/local/bin/player-osd-ip"

# Tunables
install -v -m 644 -o root -g root files/etc/player.default    "${ROOTFS_DIR}/etc/default/player"

# systemd units
install -v -m 644 -o root -g root files/systemd/player.service     "${ROOTFS_DIR}/etc/systemd/system/player.service"
install -v -m 644 -o root -g root files/systemd/usb-media@.service "${ROOTFS_DIR}/etc/systemd/system/usb-media@.service"
install -v -m 644 -o root -g root files/systemd/player-osd-ip.service "${ROOTFS_DIR}/etc/systemd/system/player-osd-ip.service"
install -v -m 644 -o root -g root files/systemd/player-osd-ip.timer   "${ROOTFS_DIR}/etc/systemd/system/player-osd-ip.timer"

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
