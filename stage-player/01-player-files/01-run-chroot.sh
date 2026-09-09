#!/bin/bash -e

# The unit ships with User=pi. If FIRST_USER_NAME differs, systemd fails with
# the unhelpful "Failed to determine user credentials: No such process" and
# restart-loops forever, so rewrite it here.
sed -i "s/^User=pi$/User=${FIRST_USER_NAME}/; s/^Group=pi$/Group=${FIRST_USER_NAME}/" \
	/etc/systemd/system/player.service

# Fail the build rather than shipping an image whose player cannot start.
if ! id "${FIRST_USER_NAME}" >/dev/null 2>&1; then
	echo "FATAL: FIRST_USER_NAME=${FIRST_USER_NAME} does not exist in the rootfs"
	exit 1
fi

# Console only: never pull in a desktop session, which would hold DRM master
# and make --gpu-context=drm impossible.
systemctl set-default multi-user.target

# tty1 belongs to the player, not to a login prompt.
# Disabling getty@tty1 is NOT sufficient: logind spawns autovt@tty1.service
# (a separate symlink to getty@.service) whenever VT1 is activated, which grabs
# the console back after the player stops and blocks the next start. Turning the
# autovt machinery off entirely is the only reliable fix for a kiosk.
systemctl disable getty@tty1.service || true
systemctl mask getty@tty1.service || true
install -d -m 755 /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-player-no-autovt.conf <<'LOGIND'
[Login]
NAutoVTs=0
ReserveVT=0
LOGIND

# NAutoVTs=0 is global: it stops logind spawning a getty on EVERY VT, so
# Ctrl+Alt+F2..F6 would otherwise land on a blank console with no login prompt.
# Statically enabling one getty restores a maintenance console. This is not
# affected by NAutoVTs, which only governs logind's on-demand spawning, and it
# never touches tty1, so the player's hold on VT1 is unchanged.
systemctl enable getty@tty2.service

systemctl enable player.service

# Refreshes the hostname/IP overlay shown over the fallback loop.
systemctl enable player-osd-ip.timer

# usb-media@.service is template-instantiated by udev; it must not be "enabled".
systemctl daemon-reload || true

# DRM + input access for the player user. Deliberately not "|| true": if this
# fails the player cannot acquire DRM master and the image is useless.
usermod -aG video,render,input "${FIRST_USER_NAME}"

# Trim boot time: nothing here waits on the network, and a signage box that
# blocks for 90s on a missing DHCP lease is a bad box.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
