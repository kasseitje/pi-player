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
systemctl disable getty@tty1.service || true

systemctl enable player.service

# usb-media@.service is template-instantiated by udev; it must not be "enabled".
systemctl daemon-reload || true

# DRM + input access for the player user. Deliberately not "|| true": if this
# fails the player cannot acquire DRM master and the image is useless.
usermod -aG video,render,input "${FIRST_USER_NAME}"

# Trim boot time: nothing here waits on the network, and a signage box that
# blocks for 90s on a missing DHCP lease is a bad box.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
