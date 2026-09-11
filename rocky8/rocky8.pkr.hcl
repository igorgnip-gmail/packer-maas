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
  default     = "rocky8.tar.gz"
  description = "The filename of the tarball to produce"
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

locals {
  # Priority: TEMPLATE_USER_PASSWORD_HASH env var, then ~/.hashed_password
  # (shared build/deploy secret, never committed) if present, else empty
  # -- kickstart's chpasswd -e is skipped if unset, leaving the account
  # locked (no console fallback at all if the deploy-time password
  # mechanism also fails).
  template_user_password_hash = var.template_user_password_hash != "" ? var.template_user_password_hash : try(trimspace(file(pathexpand("~/.hashed_password"))), "")
  qemu_arch = {
    "x86_64"  = "x86_64"
    "aarch64" = "aarch64"
  }
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
    # See rocky9.pkr.hcl: "max" under aarch64 TCG is extremely slow to
    # translate (confirmed live -- over an hour stuck vs. <30s to a
    # working GRUB menu with cortex-a72). host_is_arm=true keeps "host"
    # passthrough since real hardware isn't affected.
    "aarch64" = var.host_is_arm ? "host" : "cortex-a72"
  }

  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/BaseOS/${var.architecture}/os" : "--mirrorlist='http://mirrors.rockylinux.org/mirrorlist?arch=${var.architecture}&repo=BaseOS-8'"
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/AppStream/${var.architecture}/os" : "--mirrorlist='https://mirrors.rockylinux.org/mirrorlist?release=8&arch=${var.architecture}&repo=AppStream-8'"
  ks_extras_repos    = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/extras/${var.architecture}/os" : "--mirrorlist='https://mirrors.rockylinux.org/mirrorlist?arch=${var.architecture}&repo=extras-8'"
}

source "qemu" "rocky8" {
  boot_command     = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/rocky8.ks <f10>"]
  boot_wait        = "5s"
  communicator     = "none"
  disk_size        = "45G"
  format           = "qcow2"
  headless         = true
  # See rocky9.pkr.hcl: download.rockylinux.org throttles down to
  # ~650KB/s after an initial burst; mirror.23m.com (Germany) sustains
  # 18-35MB/s. Checksum verification stays against the canonical source
  # deliberately -- see rocky9.pkr.hcl for the reasoning. Also switched
  # to the versioned "-8-latest-" filename for consistency with rocky9,
  # even though the unversioned name still resolves the same checksum
  # today.
  iso_checksum     = "file:http://download.rockylinux.org/pub/rocky/8/isos/${var.architecture}/CHECKSUM"
  iso_url          = "https://mirror.23m.com/rocky/8/isos/${var.architecture}/Rocky-8-latest-${var.architecture}-boot.iso"
  iso_target_path  = "packer_cache/Rocky-8-latest-${var.architecture}-boot.iso"
  memory           = 2048
  cores            = 4
  qemu_binary      = "qemu-system-${lookup(local.qemu_arch, var.architecture, "")}"
  qemuargs = [
    # See rocky9.pkr.hcl for why: -serial stdio produces zero output
    # when packer runs backgrounded/non-interactive (no controlling tty).
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4452,server=on,wait=off,telnet=on,logfile=console.log"],
    ["-serial", "chardev:consolesock"],
    ["-boot", "strict=off"],
    ["-device", "qemu-xhci"],
    ["-device", "usb-kbd"],
    ["-device", "virtio-net-pci,netdev=net0"],
    ["-netdev", "user,id=net0"],
    ["-device", "virtio-blk-pci,drive=drive0,bootindex=0"],
    ["-device", "virtio-blk-pci,drive=cdrom0,bootindex=1"],
    ["-machine", "${lookup(local.qemu_machine, var.architecture, "")}"],
    ["-cpu", "${lookup(local.qemu_cpu, var.architecture, "")}"],
    ["-device", "virtio-gpu-pci"],
    ["-global", "driver=cfi.pflash01,property=secure,value=off"],
    ["-drive", "if=pflash,format=raw,unit=0,id=ovmf_code,readonly=on,file=/usr/share/${lookup(local.uefi_imp, var.architecture, "")}/${lookup(local.uefi_imp, var.architecture, "")}_CODE${lookup(local.uefi_sfx, var.architecture, "")}.fd"],
    ["-drive", "if=pflash,format=raw,unit=1,id=ovmf_vars,file=${var.architecture}_VARS.fd"],
    ["-drive", "file=output-rocky8/packer-rocky8,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/Rocky-8-latest-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/rocky8.ks" = templatefile("${path.root}/http/rocky8.ks.pkrtpl.hcl",
      {
        KS_PROXY                 = local.ks_proxy,
        KS_OS_REPOS              = local.ks_os_repos,
        KS_APPSTREAM_REPOS       = local.ks_appstream_repos,
        KS_EXTRAS_REPOS          = local.ks_extras_repos,
        TEMPLATE_USER_PASSWORD_HASH = local.template_user_password_hash
      }
    )
  }
}

build {
  sources = ["source.qemu.rocky8"]

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
