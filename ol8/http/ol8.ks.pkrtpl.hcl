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
# --disabled (not --location=mbr, a legacy-BIOS directive) -- this
# build now runs under UEFI (see ol8.pkr.hcl's qemuargs), matching
# rocky8/alma8's own kickstarts.
bootloader --disabled
rootpw --plaintext password

# Add the fleet-standard local user. No --password here -- set via
# chpasswd in %post instead (a hashed value, not kickstart's own plaintext
# option), matching this pipeline's shared-hash convention (same pattern
# as rocky9/alma9's own kickstarts). No sshd hardening block in this
# file yet, unlike ol9.
user --groups=wheel --name=oraclelinux --gecos="Oracle Linux"

repo --name="ol8_AppStream" ${KS_APPSTREAM_REPOS} ${KS_PROXY}

zerombr
clearpart --all --initlabel
part / --size=1 --grow --asprimary --fstype=ext4

%post --erroronfail --log=/var/log/kickstart_post.log
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
rm -f /etc/NetworkManager/system-connections/*

# Kickstart copies install boot options. Serial is turned on for logging with
# Packer which disables console output. Disable it so console output is shown
# during deployments
sed -i 's/^GRUB_TERMINAL=.*/GRUB_TERMINAL_OUTPUT="console"/g' /etc/default/grub
sed -i '/GRUB_SERIAL_COMMAND="serial"/d' /etc/default/grub
sed -ri 's/(GRUB_CMDLINE_LINUX=".*)\s+console=ttyS0(.*")/\1\2/' /etc/default/grub
sed -i 's/GRUB_ENABLE_BLSCFG=.*/GRUB_ENABLE_BLSCFG=false/g' /etc/default/grub

dnf clean all

# Broken SSH host-key generation and the target going unreachable after
# its post-install reboot are both symptoms of the SAME root cause,
# confirmed via a live deploy + journalctl traceback: Oracle's cloud-init-23.4-
# 7.0.4.el8_10.12 build (the newest in ol8_appstream as of this date)
# backported a newer upstream cloudinit/net/sysconfig.py that calls
# util.load_text_file(), without backporting the matching util.py --
# that function does not exist there (only the older load_file() does),
# so it's a genuine Oracle packaging regression, not an upstream
# cloud-init bug. AttributeError fires deterministically inside
# sysconfig.py's _render_dns() whenever a resolv.conf already exists at
# render time, which crashes the WHOLE 'init' stage (main_init() has no
# try/except around apply_network_config()) before cloud_init_modules
# (set_hostname, users-groups, etc.) ever run -- explains both the
# never-generated SSH host keys (worked around below) and the target
# going unreachable after its own post-install reboot (hostname/
# network config silently never applied on the affected boot).
# Confirmed via a binary diff across every ol8_appstream build back to
# 22.1: 23.4-7.0.3.el8_10.11 (one point-release earlier, same 23.4
# upstream version) still only has util.load_file() referenced anywhere
# in the package -- last known-good build. Downgrading here (noarch,
# same package works on both arches) bakes in a working cloud-init at
# image-build time rather than depending on Oracle's currently-latest
# repo build. Deliberately NOT version-locked -- if this ships in a
# later dnf update, real fixed data source should apply fine again by
# then per an approved user judgment call (2026-09-11): "if user
# updates cloud-init it will be either fixed or at least network would
# already be setup [by the time it re-runs]".
dnf downgrade -y https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/getPackage/cloud-init-23.4-7.0.3.el8_10.11.noarch.rpm

# Oracle Linux 8's own cloud-init package (even the downgraded,
# network-fixed build above) still disables systemd's reliable
# sshd-keygen@.service in favor of doing SSH host-key generation
# itself via its own ssh cc module -- keep this removal regardless of
# the downgrade above, since it's a cheap, independent belt-and-braces
# fix (rely on systemd's own well-tested keygen path instead of
# cloud-init's for this one thing specifically). rocky8/alma9/etc.
# don't need this (their own cloud-init packages don't disable it), so
# this is deliberately OL8-only rather than a shared template change.
rm -f /etc/systemd/system/sshd-keygen@.service.d/disable-sshd-keygen-if-cloud-init-active.conf

# Passwordless sudo for oraclelinux
echo "oraclelinux ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/oraclelinux
chmod 440 /etc/sudoers.d/oraclelinux

# Fleet-wide shared password hash (same value cloud-init sets at deploy
# time -- duplicated here so the account is usable from local KVM/
# console even before cloud-init ever runs). Temporary/interim value, not a long-term
# secret -- see the shared-hash convention note above.
TEMPLATE_USER_PASSWORD_HASH='${TEMPLATE_USER_PASSWORD_HASH}'
if [ -n "$TEMPLATE_USER_PASSWORD_HASH" ]; then
    echo "oraclelinux:$TEMPLATE_USER_PASSWORD_HASH" | chpasswd -e
fi

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

# Harden sshd: root login must use a key (never a password), and no user
# may password-auth in at all. Uses the modern drop-in convention
# (/etc/ssh/sshd_config.d/*.conf) rather than editing the vendor-shipped
# sshd_config directly. That only actually takes effect if something
# includes the directory, and sshd_config uses first-value-wins semantics
# -- confirmed live against a real deployed AlmaLinux 8 target that EL8's
# shipped sshd_config has NO Include directive at all (EL9 ships one by
# default), which would make any drop-in file silently inert. Removing
# any existing Include line and re-adding it as line 1 (rather than just
# checking presence) guarantees our drop-ins are parsed first and win,
# regardless of where the stock file already places it or what it
# already sets explicitly further down.
sed -i -E '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/sshd_config\.d\//d' /etc/ssh/sshd_config
sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
printf '%s\n' 'PermitRootLogin prohibit-password' > /etc/ssh/sshd_config.d/root.conf
printf '%s\n' 'PasswordAuthentication no' > /etc/ssh/sshd_config.d/users.conf

# SELinux: force the relabel now, using this chroot's own guest kernel
# (not the deploy-time chroot's kernel) -- avoids shipping an
# image that needs a first-boot autorelabel-then-self-reboot cycle
# (confirmed live 2026-09-07: journalctl -b -1 on a freshly
# deployed target showed selinux-autorelabel running for ~30s then a
# clean systemd-initiated reboot, triggered by /.autorelabel).
# No -T (thread count) -- confirmed live 2026-09-09 building this image
# on arm64: this ISO's bundled policycoreutils doesn't support -T at
# all ("/sbin/fixfiles: illegal option -- T"), a fatal kickstart %post
# error under --erroronfail. Plain `restore` works identically on both
# arches, just single-threaded.
fixfiles restore
rm -f /.autorelabel

# The python3.12 package installed below (%packages) registers itself as
# an `alternatives` slave for the bare `python3` command at a much
# higher priority than the OS-default python3.6 (confirmed via `rpm -qp
# --scripts python3.12*.rpm`: `alternatives --install /usr/bin/python3
# python3 /usr/bin/python3.12 31200 ...`), which in `auto` mode silently
# makes python3.12 the system-wide default the instant it's installed.
# We only want python3.12 available at its own versioned path for
# post-deploy configuration management to target explicitly -- not to
# change what every other script/tool on this OS gets when it runs
# `python3`.
# Pin the alternative back to the distro's own default immediately after
# install so EL8's normal python3 (3.6, matching every other unmodified
# EL8 system) is untouched.
alternatives --set python3 /usr/bin/python3.6
%end

%packages --ignoremissing
@core
bash-completion
cloud-init
# EL8's stock python3 is 3.6, too old for modern automation-tool module
# payloads (which need 3.7+ for `from __future__ import annotations`).
# Gives post-deploy configuration management a modern interpreter to
# target explicitly, without changing the OS default. CONFIRMED
# 2026-09-08 this line is NOT the cause of a separate, transient
# empty-install failure seen on OL8 (the byte-identical original
# kickstart, with this line absent entirely, reproduced the exact same
# failure against Oracle's own mirror) -- see ISSUES.md:
# ol8-transient-build-failure.
python3.12
# cloud-init only requires python3-oauthlib with MAAS. As such upstream
# removed this dependency.
python3-oauthlib
cloud-utils-growpart
rsync
tar
patch
yum-utils
# grub2-efi-* ships grub signed for UEFI secure boot. If grub2-efi-*-modules
# is installed grub will be generated on deployment and unsigned which breaks
# UEFI secure boot.
# Wildcarded (not hardcoded grub2-efi-x64/shim-x64) -- confirmed live
# 2026-09-09: the hardcoded amd64-only package names get silently
# dropped by --ignoremissing on arm64 (grub2-efi-aa64/shim-aa64 there
# instead), which meant grub2 itself was NEVER installed at all on the
# first arm64 attempt -- no /etc/default/grub, every later sed against
# it a fatal %post error. Matches ol9/ol10's own already-fixed pattern.
grub2-efi-*
efibootmgr
shim-*
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
-plymouth
# Remove ALSA firmware
-a*-firmware
# Remove Intel wireless firmware
-i*-firmware
%end
