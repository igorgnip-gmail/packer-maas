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
  default     = "ol9.tar.gz"
  description = "The filename of the tarball to produce"
}

# NOT a straight ${architecture} substitution like rocky9/alma9 -- the
# arm64 boot ISO Oracle publishes for OL9 only exists in a UEK
# (Unbreakable Enterprise Kernel) variant ("-boot-uek.iso"), no plain
# "-boot.iso" equivalent on that arch (confirmed live: 404 on the plain
# path, boot-uek.iso the only boot ISO listed in Oracle's own checksum
# manifest for aarch64). amd64 keeps the plain boot ISO (RHCK default).
# Same situation as ol10, ported here the same way.
locals {
  iso_url = {
    "amd64" = "https://yum.oracle.com/ISOS/OracleLinux/OL9/u2/x86_64/OracleLinux-R9-U2-x86_64-boot.iso"
    "arm64" = "https://yum.oracle.com/ISOS/OracleLinux/OL9/u2/aarch64/OracleLinux-R9-U2-aarch64-boot-uek.iso"
  }
  iso_checksum_path = {
    "amd64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R9-U2-Server-x86_64.checksum"
    "arm64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R9-U2-Server-aarch64.checksum"
  }
  qemu_arch_dir = {
    "amd64" = "x86_64"
    "arm64" = "aarch64"
  }
  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}" : "--url='https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}'"
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/" : "--baseurl='https://yum.oracle.com/repo/OracleLinux/OL9/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/'"

  # Same qemu machine/cpu/UEFI lookup pattern as rocky9.pkr.hcl/ol10.pkr.hcl.
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
  description = "SHA-512 crypt hash for the local fleet-standard user's console/KVM-fallback password. Never hardcode this in the template -- set the TEMPLATE_USER_PASSWORD_HASH env var before building. Empty by default (kickstart's chpasswd -e is skipped if unset, leaving the account locked)."
}

variable "timeout" {
  type        = string
  default     = "1h"
  description = "Timeout for building the image"
}

source "qemu" "ol9" {
  # NOT the isolinux/syslinux <tab>-then-enter convention this file
  # used to have (that only worked under legacy BIOS -- Oracle's ISO
  # boots ISOLINUX there, where TAB edits the boot line directly).
  # Under UEFI it boots GRUB2 instead, where TAB just drops into the
  # raw command shell (grub>) and the typed text isn't a valid
  # standalone grub command -- confirmed live 2026-08-31: the VM sat at
  # a bare `grub>` prompt for the full 1h timeout, never actually
  # booting, after the OVMF fix landed. GRUB2 needs `e` (multi-line
  # kernel-line editor) + arrow navigation + F10 instead, same pattern
  # rocky9.pkr.hcl/alma9.pkr.hcl already use successfully under UEFI.
  # Down-count copied from rocky9/alma9 as a starting point (Oracle's
  # grub.cfg stanza structure not independently confirmed to have the
  # same line count) -- verify via console.log within the first ~30s
  # of a build before trusting a full unattended run.
  boot_command    = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ol9.ks <f10>"]
  boot_wait       = "3s"
  communicator    = "none"
  disk_size       = "4G"
  format          = "qcow2"
  headless        = true
  iso_checksum    = "file:${lookup(local.iso_checksum_path, var.architecture, "")}"
  iso_url         = lookup(local.iso_url, var.architecture, "")
  iso_target_path = "packer_cache/ol9-${var.architecture}-boot.iso"
  memory          = 2048
  qemu_binary     = "qemu-system-${lookup(local.qemu_arch_dir, var.architecture, "")}"
  # See rocky9.pkr.hcl for why: -serial stdio produces zero output when
  # packer runs backgrounded/non-interactive (no controlling tty).
  #
  # 2026-08-31: added OVMF (UEFI) pflash drives -- this build previously
  # ran under plain legacy BIOS (no firmware drives at all), which means
  # anaconda configured a BIOS/MBR bootloader at image-build time
  # regardless of the grub2-efi-x64/shim-x64/efibootmgr packages already
  # being installed via %packages (those got installed but never
  # correctly activated, since anaconda's own bootloader setup follows
  # the firmware it's actually running under). The real fleet this image
  # deploys onto is UEFI-only -- curtin was effectively redoing
  # bootloader setup at deploy time to correct for this mismatch, wasted
  # and fragile work compared to the image just being UEFI-correct from
  # the start (same fix as rocky9/alma9/debian, which never had this bug).
  #
  # Explicit disk/cdrom/network/keyboard devices are REQUIRED alongside
  # OVMF, not optional -- found live while building ol10.pkr.hcl (same
  # session): trimming qemuargs down to chardev/serial/cpu only (this
  # file's OWN previous state, copied as "proven" into ol10) actually
  # left the VM's UEFI firmware with no bootable CD-ROM device at all
  # (confirmed via console.log: Boot Manager Menu offered only PXE/
  # HTTP/Shell, a full hour of silence, "Failed to shutdown"). Whatever
  # implicit device-filling this ol9 build originally relied upon
  # apparently only worked under legacy BIOS, not UEFI, with the
  # packer-plugin-qemu version now in use -- rocky9.pkr.hcl's full
  # explicit set (proven working, twice, same session) is required.
  qemuargs = [
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4448,server=on,wait=off,telnet=on,logfile=console.log"],
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
    ["-drive", "file=output-ol9/packer-ol9,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/ol9-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/ol9.ks" = templatefile("${path.root}/http/ol9.ks.pkrtpl.hcl",
      {
        KS_PROXY                    = local.ks_proxy,
        KS_OS_REPOS                 = local.ks_os_repos,
        KS_APPSTREAM_REPOS          = local.ks_appstream_repos,
        TEMPLATE_USER_PASSWORD_HASH = var.template_user_password_hash
      }
    )
  }

}

build {
  sources = ["source.qemu.ol9"]

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
