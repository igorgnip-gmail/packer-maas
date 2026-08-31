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

variable "ol8_iso_url" {
  type    = string
  default = "https://yum.oracle.com/ISOS/OracleLinux/OL8/u8/x86_64/x86_64-boot.iso"
}

variable "ol8_sha256sum_path" {
  type    = string
  default = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R8-U8-Server-x86_64.checksum"
}

# use can use "--url" to specify the exact url for os repo
variable "ks_os_repos" {
  type    = string
  default = "--url='https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/x86_64'"
}

# Use --baseurl to specify the exact url for AppStream repo
variable "ks_appstream_repos" {
  type    = string
  default = "--baseurl='https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/'"
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

locals {
  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/baseos/latest/x86_64" : var.ks_os_repos
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/appstream/x86_64/" : var.ks_appstream_repos
}

source "qemu" "ol8" {
  boot_command    = ["<up><tab> ", "inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ol8.ks ", "console=ttyS0 inst.cmdline", "<enter>"]
  boot_wait       = "3s"
  communicator    = "none"
  disk_size       = "4G"
  format          = "qcow2"
  headless        = true
  iso_checksum    = "file:${var.ol8_sha256sum_path}"
  iso_url         = var.ol8_iso_url
  iso_target_path = "packer_cache/ol8-boot.iso"
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
    ["-serial", "stdio"],
    ["-boot", "strict=off"],
    ["-device", "qemu-xhci"],
    ["-device", "usb-kbd"],
    ["-device", "virtio-net-pci,netdev=net0"],
    ["-netdev", "user,id=net0"],
    ["-device", "virtio-blk-pci,drive=drive0,bootindex=0"],
    ["-device", "virtio-blk-pci,drive=cdrom0,bootindex=1"],
    ["-machine", "accel=kvm"],
    ["-cpu", "host"],
    ["-device", "virtio-gpu-pci"],
    ["-global", "driver=cfi.pflash01,property=secure,value=off"],
    ["-drive", "if=pflash,format=raw,unit=0,id=ovmf_code,readonly=on,file=OVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,unit=1,id=ovmf_vars,file=OVMF_VARS.fd"],
    ["-drive", "file=output-ol8/packer-ol8,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/ol8-boot.iso,if=none,id=cdrom0,media=cdrom"]
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
