packer {
  required_version = ">= 1.11.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0, < 1.1.2"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "filename" {
  type        = string
  default     = "ol10.tar.gz"
  description = "The filename of the tarball to produce"
}

# NOT a straight ${architecture} substitution like rocky9/alma9 -- the
# arm64 boot ISO Oracle publishes for OL10 only exists in a UEK
# (Unbreakable Enterprise Kernel) variant ("-boot-uek.iso"), no plain
# "-boot.iso" equivalent on that arch. amd64 keeps the plain boot ISO,
# which installs the Red Hat Compatible Kernel (RHCK) by default --
# see the OPEN QUESTIONS note near the bottom of this file for the one
# real unknown this leaves (whether OL10's amd64 boot menu needs an
# explicit non-default entry picked to actually get RHCK, or whether
# plain boot.iso already defaults to it -- unverified, never test-booted).
locals {
  # Priority: TEMPLATE_USER_PASSWORD_HASH env var, then ~/.hashed_password
  # (shared build/deploy secret, never committed) if present, else empty
  # -- kickstart's chpasswd -e is skipped if unset, leaving the account
  # locked (no console fallback at all if the deploy-time password
  # mechanism also fails).
  template_user_password_hash = var.template_user_password_hash != "" ? var.template_user_password_hash : try(trimspace(file(pathexpand("~/.hashed_password"))), "")
  iso_url = {
    "amd64" = "https://yum.oracle.com/ISOS/OracleLinux/OL10/u2/x86_64/OracleLinux-R10-U2-x86_64-boot.iso"
    "arm64" = "https://yum.oracle.com/ISOS/OracleLinux/OL10/u2/aarch64/OracleLinux-R10-U2-aarch64-boot-uek.iso"
  }
  # Oracle's checksum manifests are PGP-clearsigned files covering every
  # ISO variant for that release/arch (dvd/boot/boot-uek) in one
  # document -- same file Packer's `file:` checksum type already parses
  # correctly for ol9 (see ol9.pkr.hcl's ol9_sha256sum_path), just a
  # different filename convention (linux.oracle.com, not yum.oracle.com).
  # Confirmed live (curl) both exist and both list the exact ISO
  # filenames above:
  #   https://linux.oracle.com/security/gpg/checksum/OracleLinux-R10-U2-Server-x86_64.checksum
  #   https://linux.oracle.com/security/gpg/checksum/OracleLinux-R10-U2-Server-aarch64.checksum
  iso_checksum_path = {
    "amd64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R10-U2-Server-x86_64.checksum"
    "arm64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R10-U2-Server-aarch64.checksum"
  }
  # yum.oracle.com's repo path structure confirmed identical to OL9's,
  # just with the arch segment substitutable and OL10 in the path
  # (confirmed live via curl against baseos/appstream repomd.xml for
  # both x86_64 and aarch64) -- generalizes ol9.pkr.hcl's hardcoded
  # x86_64 paths to work for both architectures.
  qemu_arch_dir = {
    "amd64" = "x86_64"
    "arm64" = "aarch64"
  }
  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}" : "--url='https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}'"
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/" : "--baseurl='https://yum.oracle.com/repo/OracleLinux/OL10/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/'"

  # Same qemu machine/cpu/UEFI lookup pattern as rocky9.pkr.hcl -- see
  # that file's own comments for the TCG-vs-KVM "max"/"cortex-a72"
  # rationale, unchanged here.
  uefi_imp = {
    "x86_64"  = "OVMF"
    "aarch64" = "AAVMF"
  }
  uefi_sfx = {
    "x86_64"  = "${var.ovmf_suffix}"
    "aarch64" = ""
  }
  qemu_machine = {
    "x86_64"  = "accel=kvm"
    "aarch64" = var.host_is_arm ? "virt,accel=kvm" : "virt"
  }
  qemu_cpu = {
    "x86_64"  = "host"
    "aarch64" = var.host_is_arm ? "host" : "cortex-a72"
  }
}

variable "architecture" {
  type        = string
  default     = "amd64"
  description = "The architecture to build the image for (amd64 or arm64)"
}

variable "host_is_arm" {
  type        = bool
  default     = false
  description = "The host architecture is aarch64"
}

variable "ovmf_suffix" {
  type        = string
  default     = ""
  description = "Suffix for OVMF CODE and VARS files. Newer systems such as Noble use _4M."
}

variable ks_proxy {
  type    = string
  default = "${env("KS_PROXY")}"
}

variable ks_mirror {
  type    = string
  default = "${env("KS_MIRROR")}"
}

variable template_user_password_hash {
  type        = string
  default     = "${env("TEMPLATE_USER_PASSWORD_HASH")}"
  description = "SHA-512 crypt hash for the local fleet-standard user's console/KVM-fallback password. Priority: TEMPLATE_USER_PASSWORD_HASH env var, then ~/.hashed_password (shared build/deploy secret, never committed) if present, else empty -- kickstart's chpasswd -e is skipped if unset, leaving the account locked (no console fallback at all if the deploy-time password mechanism also fails)."
}

variable "timeout" {
  type        = string
  default     = "1h"
  description = "Timeout for building the image"
}

source "qemu" "ol10" {
  # NOT the isolinux/syslinux <tab>-then-enter convention this was
  # copied from (ol9.pkr.hcl's OLD boot_command, which only worked
  # under legacy BIOS) -- under UEFI Oracle's ISO boots GRUB2 instead,
  # where TAB just drops into the raw command shell (grub>) and the
  # typed text isn't a valid standalone grub command. Confirmed live
  # 2026-08-31: sat at a bare `grub>` prompt for the full 1h timeout,
  # never booting. GRUB2 needs `e` (multi-line kernel-line editor) +
  # arrow navigation + F10 instead, same pattern rocky9.pkr.hcl/
  # alma9.pkr.hcl already use successfully under UEFI. Also resolves
  # the earlier UEK-vs-RHCK OPEN QUESTION below: confirmed via
  # console.log, OL10's amd64 boot menu has no separate UEK/RHCK entry
  # at all ("Install Oracle Linux 10.2.0" / "...in FIPS mode" /
  # "Troubleshooting" only) -- nothing to navigate around there.
  # Down-count copied from rocky9/alma9 as a starting point (Oracle's
  # grub.cfg stanza structure not independently confirmed to have the
  # same line count) -- verify via console.log within the first ~30s
  # of a build before trusting a full unattended run.
  boot_command    = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ol10.ks <f10>"]
  boot_wait       = "3s"
  communicator    = "none"
  disk_size       = "4G"
  format          = "qcow2"
  headless        = true
  iso_checksum    = "file:${lookup(local.iso_checksum_path, var.architecture, "")}"
  iso_url         = lookup(local.iso_url, var.architecture, "")
  iso_target_path = "packer_cache/ol10-${var.architecture}-boot.iso"
  memory          = 2048
  qemu_binary     = "qemu-system-${lookup(local.qemu_arch_dir, var.architecture, "")}"
  # Two real bugs found across three build attempts (2026-08-31):
  # 1. qemu_machine/qemu_cpu keyed by x86_64/aarch64 (copied from
  #    rocky9.pkr.hcl, where var.architecture natively IS x86_64/
  #    aarch64) but ol10's own var.architecture is amd64/arm64 -- a
  #    direct lookup always missed and returned "", producing a bare
  #    `-cpu` flag with the next flag as its value. Fixed by routing
  #    through qemu_arch_dir first (amd64/arm64 -> x86_64/aarch64),
  #    same double-lookup pattern already used for uefi_imp/uefi_sfx.
  # 2. Second attempt "fixed" this by trimming down to ol9.pkr.hcl's
  #    minimal qemuargs (chardev/serial/cpu/machine/OVMF only, no
  #    explicit disk/cdrom/network/keyboard) on the assumption Packer's
  #    QEMU builder fills those in automatically. WRONG for this
  #    packer-plugin-qemu version under UEFI: the build ran a full hour
  #    with zero output and "Failed to shutdown" -- console.log showed
  #    the VM's UEFI firmware never saw a bootable CD-ROM device at
  #    all (Boot Manager Menu offered only PXE/HTTP/Shell, no CD-ROM),
  #    confirming the disk/cdrom/network/keyboard devices genuinely
  #    need to be explicit under OVMF, same full set rocky9.pkr.hcl
  #    already uses (which built successfully, twice, same session).
  #    ol8/ol9.pkr.hcl had the identical latent bug (OVMF added without
  #    the matching explicit device set) -- fixed alongside this file.
  qemuargs = [
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4449,server=on,wait=off,telnet=on,logfile=console.log"],
    ["-serial", "chardev:consolesock"],
    ["-boot", "strict=off"],
    ["-device", "qemu-xhci"],
    ["-device", "usb-kbd"],
    ["-device", "virtio-net-pci,netdev=net0"],
    ["-netdev", "user,id=net0"],
    ["-device", "virtio-blk-pci,drive=drive0,bootindex=0"],
    ["-device", "virtio-blk-pci,drive=cdrom0,bootindex=1"],
    ["-machine", "${lookup(local.qemu_machine, lookup(local.qemu_arch_dir, var.architecture, ""), "")}"],
    ["-cpu", "${lookup(local.qemu_cpu, lookup(local.qemu_arch_dir, var.architecture, ""), "")}"],
    ["-device", "virtio-gpu-pci"],
    ["-global", "driver=cfi.pflash01,property=secure,value=off"],
    ["-drive", "if=pflash,format=raw,unit=0,id=ovmf_code,readonly=on,file=/usr/share/${lookup(local.uefi_imp, lookup(local.qemu_arch_dir, var.architecture, ""), "")}/${lookup(local.uefi_imp, lookup(local.qemu_arch_dir, var.architecture, ""), "")}_CODE${lookup(local.uefi_sfx, lookup(local.qemu_arch_dir, var.architecture, ""), "")}.fd"],
    ["-drive", "if=pflash,format=raw,unit=1,id=ovmf_vars,file=${lookup(local.qemu_arch_dir, var.architecture, "")}_VARS.fd"],
    ["-drive", "file=output-ol10/packer-ol10,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/ol10-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/ol10.ks" = templatefile("${path.root}/http/ol10.ks.pkrtpl.hcl",
      {
        KS_PROXY                    = local.ks_proxy,
        KS_OS_REPOS                 = local.ks_os_repos,
        KS_APPSTREAM_REPOS          = local.ks_appstream_repos,
        TEMPLATE_USER_PASSWORD_HASH = local.template_user_password_hash
      }
    )
  }
}

build {
  sources = ["source.qemu.ol10"]

  post-processor "shell-local" {
    inline = [
      "SOURCE=${source.name}",
      "OUTPUT=${var.filename}",
      "source ../scripts/fuse-nbd",
      "source ../scripts/fuse-tar-root",
      "rm -rf output-${source.name}",
    ]
    inline_shebang = "/bin/bash -e"
  }
}

# Resolved (was an OPEN QUESTIONS block): UEK vs RHCK kernel selection is
# confirmed by design, not an open question -- amd64 defaults to RHCK,
# arm64 to UEK (Oracle publishes no plain boot.iso for aarch64, UEK-only).
# Both amd64 and arm64 have built successfully with this template.
