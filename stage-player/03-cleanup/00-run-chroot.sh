#!/bin/bash -e
# Appliance slimming. Runs last in the stage, after every package install.

# --- cloud-init --------------------------------------------------------------
# A signage box has no cloud metadata source, so cloud-init only costs boot time
# and RAM. Note that ENABLE_CLOUD_INIT=0 in config is NOT enough on its own:
# pi-gen's run_sub_stage installs a sub-stage's NN-packages list unconditionally,
# regardless of what its NN-run.sh does, so stage2/04-cloud-init still pulls in
# cloud-init and rpi-cloud-init-mods. The config flag only suppresses the
# boot-partition seed files. Both halves are needed.
for pkg in cloud-init rpi-cloud-init-mods; do
	if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
		echo "purging ${pkg}"
		apt-get -y purge "$pkg"
	fi
done
apt-get -y autoremove --purge
rm -rf /etc/cloud /var/lib/cloud
rm -f /boot/firmware/meta-data /boot/firmware/user-data /boot/firmware/network-config

# --- apt ---------------------------------------------------------------------
# export-image/02-set-sources/01-run.sh deletes the package lists and THEN runs
# `apt-get update && apt-get dist-upgrade && apt-get clean`, so the lists it just
# removed are repopulated and ship in the image (~150 MB), while `apt-get clean`
# only empties /var/cache/apt/archives. Cleaning here alone would therefore be
# undone. What survives is this config file: the later update reads it from the
# rootfs and skips translation indices, which is where most of that bulk is.
cat > /etc/apt/apt.conf.d/99-player-slim <<'APTCONF'
// Appliance image: never download translation indices, never keep .debs.
Acquire::Languages "none";
Binary::apt::APT::Keep-Downloaded-Packages "false";
APTCONF

apt-get clean
find /var/lib/apt/lists -type f -delete
