#!/bin/bash -e

# pi-gen mounts the boot partition at /boot/firmware on Bookworm and later,
# and at /boot on older releases. Handle both.
if [ -d "${ROOTFS_DIR}/boot/firmware" ]; then
	BOOTDIR="${ROOTFS_DIR}/boot/firmware"
else
	BOOTDIR="${ROOTFS_DIR}/boot"
fi

CMDLINE="${BOOTDIR}/cmdline.txt"
CONFIG="${BOOTDIR}/config.txt"

# --- cmdline.txt : single line, append only ---------------------------------
# Kernel console blanking would black out the screen after ~10 minutes idle.
if ! grep -q "consoleblank=0" "${CMDLINE}"; then
	sed -i 's/$/ consoleblank=0/' "${CMDLINE}"
fi

# Quieter boot: no kernel spam on the display before mpv takes over.
if ! grep -q "logo.nologo" "${CMDLINE}"; then
	sed -i 's/$/ logo.nologo vt.global_cursor_default=0/' "${CMDLINE}"
fi

# Collapse any accidental newlines - cmdline.txt must remain one line.
tr -d '\n' < "${CMDLINE}" > "${CMDLINE}.tmp" && mv "${CMDLINE}.tmp" "${CMDLINE}"
echo "" >> "${CMDLINE}"

# --- config.txt -------------------------------------------------------------
cat >> "${CONFIG}" <<'CFG'

# ---- media player appliance settings ----
# Full KMS driver. Required for mpv --gpu-context=drm. 256MB CMA gives the
# V4L2 decoder and GL buffers comfortable room at 1080p on a Pi 4.
dtoverlay=vc4-kms-v3d,cma-256

# Force HDMI output even when no display is attached at boot, so the unit
# still drives a screen that gets powered on after the Pi.
hdmi_force_hotplug=1

# Suppress the rainbow splash.
disable_splash=1

# Do not blank or power down the display.
hdmi_blanking=0
CFG

echo "boot configuration applied in ${BOOTDIR}"
