#!/bin/bash -ex
#
# customize.sh - customize_script for debian-cloudimg.pkr.hcl builds used
# by this deployment (not part of upstream packer-maas). Kept minimal and
# close to stock deliberately: a real deploy failure on one server type
# this build is meant to help diagnose is unexplained, so this script
# avoids adding anything that isn't itself a diagnostic aid -- every extra
# package/config here is one more variable in that diagnosis.
#
# User/sudo setup is NOT handled here: the deploying curtin config
# creates the account with full NOPASSWD sudo at install time, same as
# every other target this pipeline deploys. SSH key injection is
# likewise curtin's job, not this image's.

export DEBIAN_FRONTEND=noninteractive

apt-get update

# Debian cloud images only enable the 'main' component by default.
# intel-microcode and the NIC firmware below all live in non-free/
# non-free-firmware -- enable everything (contrib/non-free/non-free-
# firmware), no reason to keep this image "clean" of non-free. deb822
# (.sources, trixie's default) or classic sources.list, whichever this
# image actually uses.
if compgen -G "/etc/apt/sources.list.d/*.sources" > /dev/null; then
    sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/*.sources
else
    . /etc/os-release
    echo "deb https://deb.debian.org/debian ${VERSION_CODENAME} main contrib non-free non-free-firmware" >> /etc/apt/sources.list
fi
apt-get update

# intel-microcode: cheap, concrete hypothesis for a consumer/bleeding-edge
# CPU under a server-oriented distro build -- if the image's default
# microcode predates that CPU's steppings, symptoms could range from
# silent hangs to outright boot failure. Costs nothing to include even if
# this isn't the actual cause.
apt-get install --no-install-recommends -y intel-microcode

# NIC firmware: some drivers (notably Intel ice/E810) require an external
# DDP package or the driver silently runs in a degraded mode -- link
# comes up, but higher-level negotiation (e.g. LACP) never converges.
# Debian's package names differ from Ubuntu's split (`firmware-*` here
# vs Ubuntu's `linux-firmware-*`); contents verified via dpkg-deb -c
# against the real .debs before adding this: firmware-intel-misc has
# usr/lib/firmware/intel/ice/ddp/ice.pkg, firmware-qlogic has
# usr/lib/firmware/qed/qed_init_values_zipped-*.bin (FastLinQ/QL41xxx),
# firmware-realtek is self-explanatory. No unzstd decompression step is
# needed here (unlike a kernel with firmware-decompression support
# disabled): Debian's firmware-intel-misc ships ice.pkg already plain,
# not compressed. Broadcom (bnxt_en) and Mellanox ConnectX need no
# runtime firmware file at all, so nothing to add for those vendors.
apt-get install --no-install-recommends -y \
    firmware-intel-misc \
    firmware-realtek \
    firmware-qlogic

# GPU firmware (i915 GuC/DMC, e.g. i915/tgl_guc_70.bin, i915/adls_dmc_ver2_01.bin)
# -- confirmed missing live 2026-08-31 (dpkg -l showed "un", not installed):
# i915 failed every GuC firmware fetch with -ENOENT and declared the GPU
# "wedged". Confirmed harmless in practice on the server hardware this was
# found on (Supermicro board's actual console/KVM video path is the ASPEED
# `ast` driver, not the CPU's iGPU -- ast loaded with zero errors) -- added
# anyway for image-build hygiene/completeness, cheap and correct regardless
# of which GPU a given target actually uses for display.
#
# firmware-intel-graphics, NOT firmware-misc-nonfree -- corrected same
# session after the first rebuild: verified directly against packages.
# debian.org's contents search that firmware-misc-nonfree does NOT ship
# any i915/* files at all (confirmed empty on the built image too, despite
# the package installing successfully -- it was simply the wrong package).
# Debian splits Intel graphics firmware into its own dedicated package.
# firmware-misc-nonfree kept anyway -- it does ship other real firmware
# (audio codec blobs etc.), just not this.
apt-get install --no-install-recommends -y \
    firmware-misc-nonfree \
    firmware-intel-graphics

# mdadm: curtin's builtin curthooks unconditionally tries to write
# /etc/mdadm/mdadm.conf into the target during the curthooks phase
# (regardless of whether this specific target actually uses raid --
# confirmed live: a plain single/dual-disk, no-raid install still hit
# "Mdadm configuration found, enabling service" then crashed with
# `[Errno 2] No such file or directory: '/mnt/target/etc/mdadm/mdadm.conf'`
# because the directory doesn't exist without the package). Every other
# target this pipeline deploys already ships mdadm in its base image;
# Debian's cloud image doesn't, so it needs adding explicitly here.
apt-get install --no-install-recommends -y mdadm

# Hardware/driver diagnostic tooling -- useful regardless of what's
# actually wrong, available for post-mortem investigation on the
# deployed target.
apt-get install --no-install-recommends -y \
    pciutils \
    usbutils \
    ethtool \
    dmidecode \
    lshw \
    smartmontools \
    ipmitool

# Persistent systemd journal -- survives a reboot/crash instead of the
# tmpfs-backed default.
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal || true

# cloud-init's own SSH module manages /etc/ssh/sshd_config.d/50-cloud-init.conf
# and rewrites it based on the ssh_pwauth cloud-config directive -- confirmed
# live 2026-08-31 that leaving this unset produces PasswordAuthentication yes
# in that file (this cloud-init version's effective default), and that a
# manually-edited/statically-written version of that same file does NOT
# survive here the way it does on the RHEL-family images (those get it via a
# static %post write, since RHEL images don't have cloud-init managing
# sshd_config.d at all). Explicit false here is what actually sticks, since
# it's cloud-init's own module writing the correct value from its own
# config, not something fighting cloud-init for ownership of the file.
mkdir -p /etc/cloud/cloud.cfg.d
printf '%s\n' '#cloud-config' 'ssh_pwauth: false' > /etc/cloud/cloud.cfg.d/99-disable-ssh-pwauth.cfg

apt-get clean
rm -rf /var/lib/apt/lists/*
