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
timezone UTC --utc

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
# No need for bootloader
bootloader --disabled
# Wipe invalid partition tables
zerombr
# Erase all partitions and assign default labels
clearpart --all --initlabel
# Initialize the primary root partition with ext4 filesystem
part / --size=1 --grow --asprimary --fstype=ext4

# Set root password
rootpw --plaintext password

# Add the fleet-standard local user. No --password here -- set via
# chpasswd in %post instead (a hashed value, not kickstart's own plaintext
# option), matching this pipeline's shared-hash convention.
user --groups=wheel --name=rockylinux --gecos="Rocky Linux"

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

# Passwordless sudo for rockylinux
echo "rockylinux ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/rockylinux
chmod 440 /etc/sudoers.d/rockylinux

# Fleet-wide shared password hash (same value ansible-bmc's
# templates/curtin/3-extract.yaml.j2 sets via cloud-init at deploy time --
# duplicated here so the account is usable from local KVM/console even
# before cloud-init ever runs). Not yet a live deploy target (no sshd
# hardening block in this file, unlike rocky8/9) -- add that too before
# this template goes into active use.
TEMPLATE_USER_PASSWORD_HASH='${TEMPLATE_USER_PASSWORD_HASH}'
if [ -n "$TEMPLATE_USER_PASSWORD_HASH" ]; then
    echo "rockylinux:$TEMPLATE_USER_PASSWORD_HASH" | chpasswd -e
fi

#---- Optional - Install your SSH key ----
# mkdir -m0700 /home/rockylinux/.ssh/
#
# cat <<EOF >/home/rockylinux/.ssh/authorized_keys
# ssh-rsa <your_public_key_here> you@your.domain
# EOF
#
### set permissions
# chmod 0600 /home/rockylinux/.ssh/authorized_keys
#
#### fix up selinux context
# restorecon -R /home/rockylinux/.ssh/

%end

# --ignoremissing + wildcards (not hardcoded grub2-efi-x64/shim-x64) --
# this file never got either fix. Confirmed live 2026-08-31: without
# them, an aarch64 build fails outright ("Non interactive installation
# failed: Some packages, groups or modules are missing") since
# grub2-efi-x64/shim-x64/grub2-efi-x64-modules genuinely don't exist on
# that arch (grub2-efi-aa64 does) and there's no --ignoremissing to
# tolerate it -- same fix already applied to rocky9/alma9/alma10/ol10.
# Also synced the rest of this list against rocky9's more complete one
# (diagnostic tools, linux-firmware, -a*-firmware exclusion) while here.
%packages --ignoremissing
@Core
bash-completion
cloud-init
cloud-utils-growpart
rsync
tar
patch
yum-utils
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
pciutils
usbutils
ethtool
dmidecode
lshw
smartmontools
ipmitool
# Explicit rather than relying on it being pulled in as a weak/recommended
# dependency of the kernel package -- makes NIC/storage-controller firmware
# availability an explicit guarantee instead of an implicit side effect
# that could silently regress if install options ever change.
linux-firmware
# Early-load mechanism for CPU microcode updates (Intel and AMD) --
# the actual firmware blobs (including amd-ucode) are already pulled
# in as a linux-firmware dependency; this is the separate loader/
# service package, not implied by linux-firmware alone. Explicit for
# the same reason as linux-firmware itself above.
microcode_ctl
-plymouth
# Remove ALSA firmware
-a*-firmware
# Remove Intel wireless firmware
-i*-firmware
%end
