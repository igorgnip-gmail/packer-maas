url ${KS_OS_REPOS} ${KS_PROXY}
poweroff
firstboot --disable
ignoredisk --only-use=vda
lang en_US.UTF-8
keyboard us
network --device eth0 --bootproto=dhcp
firewall --enabled --service=ssh
selinux --enforcing
timezone UTC --utc
bootloader --location=mbr --driveorder="vda" --timeout=1
rootpw --plaintext password

# Add the fleet-standard local user. No --password here -- set via
# chpasswd in %post instead (a hashed value, not kickstart's own plaintext
# option), matching this pipeline's shared-hash convention (same pattern
# as rocky9/alma9's own kickstarts). Not yet a live deploy target (no
# sshd hardening block in this file, unlike ol9) -- add that too before
# this template goes into active use.
user --groups=wheel --name=oraclelinux --gecos="Oracle Linux"

repo --name="ol8_AppStream" ${KS_APPSTREAM_REPOS} ${KS_PROXY}

zerombr
clearpart --all --initlabel
part / --size=1 --grow --asprimary --fstype=ext4

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

dnf clean all

# Passwordless sudo for oraclelinux
echo "oraclelinux ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/oraclelinux
chmod 440 /etc/sudoers.d/oraclelinux

# Fleet-wide shared password hash (same value ansible-bmc's
# templates/curtin/3-extract.yaml.j2 sets via cloud-init at deploy time --
# duplicated here so the account is usable from local KVM/console even
# before cloud-init ever runs). Temporary/interim value, not a long-term
# secret -- see the shared-hash convention note above.
TEMPLATE_USER_PASSWORD_HASH='${TEMPLATE_USER_PASSWORD_HASH}'
if [ -n "$TEMPLATE_USER_PASSWORD_HASH" ]; then
    echo "oraclelinux:$TEMPLATE_USER_PASSWORD_HASH" | chpasswd -e
fi
%end

%packages
@core
bash-completion
cloud-init
# cloud-init only requires python3-oauthlib with MAAS. As such upstream
# removed this dependency.
python3-oauthlib
rsync
tar
# grub2-efi-x64 ships grub signed for UEFI secure boot. If grub2-efi-x64-modules
# is installed grub will be generated on deployment and unsigned which breaks
# UEFI secure boot.
grub2-efi-x64
efibootmgr
shim-x64
dosfstools
lvm2
mdadm
device-mapper-multipath
iscsi-initiator-utils
-plymouth
# Remove Intel wireless firmware
-i*-firmware
%end
