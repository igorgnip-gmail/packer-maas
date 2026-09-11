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
  default     = "ol8.tar.gz"
  description = "The filename of the tarball to produce"
}

# arm64's OL8 boot ISO exists only as a UEK (Unbreakable Enterprise
# Kernel) variant, same situation as ol9/ol10 -- confirmed live: plain
# "aarch64-boot.iso" 404s, "aarch64-boot-uek.iso" is the real one, at
# the same u8 path amd64 uses. Unlike ol9/ol10's "OracleLinux-R9-U2-..."
# filenames, OL8's u8 tree keeps the plain unversioned filenames on
# both arches ("x86_64-boot.iso" / "aarch64-boot-uek.iso").
locals {
  iso_url = {
    "amd64" = "https://yum.oracle.com/ISOS/OracleLinux/OL8/u8/x86_64/x86_64-boot.iso"
    "arm64" = "https://yum.oracle.com/ISOS/OracleLinux/OL8/u8/aarch64/aarch64-boot-uek.iso"
  }
  iso_checksum_path = {
    "amd64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R8-U8-Server-x86_64.checksum"
    "arm64" = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R8-U8-Server-aarch64.checksum"
  }
  qemu_arch_dir = {
    "amd64" = "x86_64"
    "arm64" = "aarch64"
  }
  # Same qemu machine/cpu/UEFI lookup pattern as rocky9.pkr.hcl/ol9.pkr.hcl.
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
  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}" : "--url='https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/${lookup(local.qemu_arch_dir, var.architecture, "")}'"
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/" : "--baseurl='https://yum.oracle.com/repo/OracleLinux/OL8/appstream/${lookup(local.qemu_arch_dir, var.architecture, "")}/'"
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

source "qemu" "ol8" {
  # NOT the isolinux/syslinux <tab>-then-enter convention this file
  # used to have (that only worked under legacy BIOS) -- see ol9.pkr.hcl's
  # own boot_command comment for the live failure this fixes (confirmed
  # 2026-08-31: sat at a bare `grub>` prompt for a full 1h timeout under
  # UEFI, never booting). GRUB2 needs `e` + arrow navigation + F10
  # instead, same pattern rocky9.pkr.hcl/alma9.pkr.hcl already use.
  boot_command    = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ol8.ks <f10>"]
  boot_wait       = "3s"
  communicator    = "none"
  # 2026-09-08: was "4G" -- always fragile/marginal (rocky8/alma8, same
  # EL8 family and roughly the same @core+extras package set, both use
  # "45G"), and tipped over into a real DNF transaction-test failure
  # ("installing package X needs NNNMB on the / filesystem", growing past
  # what a 4G disk can hold) once Oracle's own repo package sizes grew
  # slightly since this file was written. See ISSUES.md:
  # ol8-disk-size-too-small.
  disk_size       = "45G"
  format          = "qcow2"
  headless        = true
  iso_checksum    = "file:${lookup(local.iso_checksum_path, var.architecture, "")}"
  iso_url         = lookup(local.iso_url, var.architecture, "")
  iso_target_path = "packer_cache/ol8-${var.architecture}-boot.iso"
  qemu_binary     = "qemu-system-${lookup(local.qemu_arch_dir, var.architecture, "")}"
  memory          = 2048
  # 2026-08-31: added OVMF (UEFI) pflash drives -- see ol9.pkr.hcl's own
  # qemuargs comment for why (same fix, same root cause: this build
  # previously ran under plain legacy BIOS, leaving anaconda's
  # bootloader setup misconfigured for the UEFI-only fleet this deploys
  # onto regardless of the grub2-efi-x64/shim-x64/efibootmgr packages
  # already installed via %packages). Explicit disk/cdrom/network/
  # keyboard devices are REQUIRED alongside OVMF -- see ol9.pkr.hcl's
  # own qemuargs comment for the live failure this fixes (found while
  # building ol10 the same session: a trimmed-down qemuargs left no
  # bootable CD-ROM device under UEFI at all).
  qemuargs = [
    # -serial stdio produces zero output when packer runs backgrounded/
    # non-interactive (no controlling tty) -- see ol9.pkr.hcl's own
    # qemuargs comment. Chardev+telnet socket captures console.log
    # regardless of tty state.
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
    ["-drive", "file=output-ol8/packer-ol8,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/ol8-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/ol8.ks" = templatefile("${path.root}/http/ol8.ks.pkrtpl.hcl",
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
  sources = ["source.qemu.ol8"]

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
