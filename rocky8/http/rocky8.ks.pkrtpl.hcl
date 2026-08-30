url ${KS_OS_REPOS} ${KS_PROXY}
repo --name="AppStream" ${KS_APPSTREAM_REPOS} ${KS_PROXY}
repo --name="Extras" ${KS_EXTRAS_REPOS} ${KS_PROXY}

eula --agreed

# Turn off after installation
poweroff

# Do not start the Inital Setup app
firstboot --disable

# System language, keyboard and timezone
lang en_US.UTF-8
keyboard us
timezone UTC --isUtc

# Set the first NIC to acquire IPv4 address via DHCP
network --device eth0 --bootproto=dhcp
# Enable firewal, let SSH through
firewall --enabled --service=ssh
# Enable SELinux with default enforcing policy
selinux --enforcing

# Do not set up XX Window System
skipx

# Initial disk setup
# Use the first paravirtualized disk
ignoredisk --only-use=vda

bootloader --disabled
zerombr
# Erase all partitions and assign default labels
clearpart --all --initlabel
# Initialize the primary root partition with ext4 filesystem
part / --size=1 --grow --asprimary --fstype=ext4

# Set root password
rootpw --plaintext password

# Add a user named packer
user --groups=wheel --name=rocky --password=rocky --plaintext --gecos="rocky"

%post --erroronfail
# workaround anaconda requirements and clear root password
passwd -d root
passwd -l root

# Clean up install config not applicable to deployed environments.
for f in resolv.conf fstab; do
    rm -f /etc/$f
    touch /etc/$f
    chown root:root /etc/$f
    chmod 644 /etc/$f
done

rm -f /etc/sysconfig/network-scripts/ifcfg-[^lo]*

# Kickstart copies install boot options. Serial is turned on for logging with
# Packer which disables console output. Disable it so console output is shown
# during deployments
sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL_OUTPUT="console"/g' /etc/default/grub
sed -i '/GRUB_SERIAL_COMMAND="serial"/d' /etc/default/grub
sed -ri 's/(GRUB_CMDLINE_LINUX=".*)\s+console=ttyS0(.*")/\1\2/' /etc/default/grub
sed -i 's/GRUB_ENABLE_BLSCFG=.*/GRUB_ENABLE_BLSCFG=false/g' /etc/default/grub 

yum clean all

# Passwordless sudo for the user 'rocky'
echo "rocky ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/rocky
chmod 440 /etc/sudoers.d/rocky

#---- Optional - Install your SSH key ----
# mkdir -m0700 /home/rocky/.ssh/
#
# cat <<EOF >/home/rocky/.ssh/authorized_keys
# ssh-rsa <your_public_key_here> you@your.domain
# EOF
#
### set permissions
# chmod 0600 /home/rocky/.ssh/authorized_keys
#
#### fix up selinux context
# restorecon -R /home/rocky/.ssh/


# Persistent systemd journal (not the volatile-only /run/log/journal
# default) -- Storage=auto only persists across reboots if this directory
# already exists, so create it up front rather than depend on something
# else remembering to.
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix=/var/log/journal

# raid arrays created by a kernel newer than this image's own can carry a
# logical_block_size superblock field this kernel's md driver doesn't
# understand and refuses to assemble. check_new_feature=0 on the
# assembling side is the documented bypass (see
# Documentation/admin-guide/md.rst) -- harmless when every disk in the
# array shares one native sector size, which is the common case.
mkdir -p /usr/lib/modprobe.d
printf '%s\n' 'options md-mod check_new_feature=0' > /usr/lib/modprobe.d/md-check-new-feature.conf

# Headless server, no monitor ever attached -- stop DRM's periodic
# connector-polling EDID reads from spamming the log with "EDID block 0
# is all zeroes" indefinitely.
printf '%s\n' 'options drm_kms_helper poll=0' > /usr/lib/modprobe.d/drm-kms-helper-poll-disable.conf

# mdadm incremental-assembly fallback: udev's own incremental-assembly
# trigger (64-md-raid-assembly.rules) can reliably fail to complete the
# second-or-later device of a raid array on this dracut/mdadm
# combination, leaving the array inactive and the boot hung waiting on
# it. This initqueue hook retries via `mdadm --assemble --scan --run`
# (assemble mode, not incremental) plus explicit module modprobe and
# `lvm vgchange -ay`, and mirrors a status snapshot to the ESP so a
# fully-hung boot still leaves a forensic trail somewhere reachable
# after the fact (the real root/journal may never come up at all).
mkdir -p /lib/dracut/hooks/initqueue
cat > /lib/dracut/hooks/initqueue/50-mdadm-incremental-fallback.sh <<'HOOK_EOF'
#!/bin/sh
mkdir -p /run/boot-diag
{
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) tick ==="
    cat /proc/mdstat 2>&1
    echo "--- blkid ---"
    blkid 2>&1
} >> /run/boot-diag/status.log
if grep -q inactive /proc/mdstat 2>/dev/null; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) mdadm-incremental-fallback: found inactive array(s), running rescue scan" >> /run/mdadm-fallback.log
fi
modprobe raid0 2>/dev/null
modprobe raid1 2>/dev/null
modprobe dm_mod 2>/dev/null
modprobe dm-raid 2>/dev/null
mdadm --assemble --scan --run >/dev/null 2>&1
lvm vgchange -ay >/dev/null 2>&1
if ! mountpoint -q /run/boot-diag/esp 2>/dev/null; then
    mkdir -p /run/boot-diag/esp
    mount -L ESP /run/boot-diag/esp 2>/dev/null
fi
if mountpoint -q /run/boot-diag/esp 2>/dev/null; then
    cp -f /run/boot-diag/status.log /run/boot-diag/esp/boot-diag.log 2>/dev/null
    [ -f /run/mdadm-fallback.log ] && cp -f /run/mdadm-fallback.log /run/boot-diag/esp/mdadm-fallback.log 2>/dev/null
fi
HOOK_EOF
chmod +x /lib/dracut/hooks/initqueue/50-mdadm-incremental-fallback.sh

# Relay the initramfs-side trace above into the standard system log once
# the real root is up (systemd preserves /run across the initrd->root
# switch-root, but /run itself is tmpfs and wiped every boot -- this is
# what makes the trace checkable across a *future* reboot, not just the
# one being watched live).
cat > /usr/lib/systemd/system/mdadm-fallback-relay.service <<'SVC_EOF'
[Unit]
Description=Relay initrd mdadm-incremental-fallback trace to syslog
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "[ -f /run/mdadm-fallback.log ] && logger -t mdadm-fallback -f /run/mdadm-fallback.log || true"
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
SVC_EOF
systemctl enable mdadm-fallback-relay.service

# Persist the same debug-tools/hook/module set across future dracut
# regenerations too -- a routine `dnf update` kernel bump triggers
# dracut's own automatic regen (via the new kernel package's %posttrans)
# with none of the above unless it's recorded somewhere dracut reads on
# every invocation, not just a one-off explicit call.
printf '%s\n' 'hostonly="no"' 'add_dracutmodules+=" lvm mdraid "' 'install_items+=" /lib/dracut/hooks/initqueue/50-mdadm-incremental-fallback.sh /usr/bin/strace /usr/bin/bash /usr/bin/find /usr/bin/which /usr/bin/ps /usr/bin/vi /usr/bin/xxd /usr/bin/date "' > /etc/dracut.conf.d/99-raid-fallback.conf

# Bake the initramfs actually containing everything above -- otherwise
# it only takes effect the next time something else triggers a dracut
# regeneration (e.g. a kernel update), not on this image's own first boot.
dracut -f --regenerate-all --no-hostonly --add "lvm mdraid" \
    --include /lib/dracut/hooks/initqueue /lib/dracut/hooks/initqueue \
    --install "strace bash find which ps vi xxd date"

%end

%packages --ignoremissing
@Core
bash-completion
cloud-init
cloud-utils-growpart
rsync
tar
patch
yum-utils
grub2-pc
grub2-efi-*
shim-*
grub2-efi-*-modules
efibootmgr
dosfstools
lvm2
mdadm
device-mapper-multipath
iscsi-initiator-utils
strace
vim-common
# Explicit rather than relying on it being pulled in as a weak/recommended
# dependency of the kernel package -- makes NIC/storage-controller firmware
# availability an explicit guarantee instead of an implicit side effect
# that could silently regress if install options ever change.
linux-firmware
-plymouth
# Remove ALSA firmware
-a*-firmware
# Remove Intel wireless firmware
-i*-firmware
%end
