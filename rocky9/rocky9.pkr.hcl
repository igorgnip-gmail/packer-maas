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
  default     = "rocky9.tar.gz"
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

variable fleet_user_password_hash {
  type        = string
  default     = "${env("FLEET_USER_PASSWORD_HASH")}"
  description = "SHA-512 crypt hash for the local fleet-standard user's console/KVM-fallback password. Never hardcode this in the template -- set the FLEET_USER_PASSWORD_HASH env var before building. Empty by default (kickstart's chpasswd -e is skipped if unset, leaving the account locked)."
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
    # "max" under aarch64 TCG (no KVM, cross-building on an x86_64 host)
    # emulates an enormous/exotic feature set that's extremely slow to
    # translate -- confirmed live: over an hour with zero boot progress
    # (99.9% CPU, no serial output at all) vs. under 30s to a fully
    # interactive GRUB menu with cortex-a72. Real ARM hardware
    # (host_is_arm=true) keeps "host" passthrough -- no TCG involved
    # there, "max" isn't the bottleneck.
    "aarch64" = var.host_is_arm ? "host" : "cortex-a72"
  }

  ks_proxy           = var.ks_proxy != "" ? "--proxy=${var.ks_proxy}" : ""
  ks_os_repos        = var.ks_mirror != "" ? "--url=${var.ks_mirror}/BaseOS/${var.architecture}/os" : "--mirrorlist='http://mirrors.rockylinux.org/mirrorlist?arch=${var.architecture}&repo=BaseOS-9'"
  ks_appstream_repos = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/AppStream/${var.architecture}/os" : "--mirrorlist='https://mirrors.rockylinux.org/mirrorlist?release=9&arch=${var.architecture}&repo=AppStream-9'"
  ks_extras_repos    = var.ks_mirror != "" ? "--baseurl=${var.ks_mirror}/extras/${var.architecture}/os" : "--mirrorlist='https://mirrors.rockylinux.org/mirrorlist?arch=${var.architecture}&repo=extras-9'"
}

source "qemu" "rocky9" {
  boot_command     = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/rocky9.ks <f10>"]
  boot_wait        = "5s"
  communicator     = "none"
  disk_size        = "45G"
  format           = "qcow2"
  headless         = true
  # Upstream's original URL (Rocky-${arch}-boot.iso, no version component)
  # 404s against Rocky's current mirror layout -- confirmed live: the
  # CHECKSUM file only lists Rocky-9.8-${arch}-boot.iso and
  # Rocky-9-latest-${arch}-boot.iso, neither of which is the versionless
  # name this template was requesting. -latest tracks the current point
  # release automatically rather than pinning to 9.8 specifically.
  # download.rockylinux.org throttles down to ~650KB/s after an initial
  # burst -- confirmed live: a 1.4GB aarch64 ISO took 30+ min and hit
  # packer's own download deadline. mirror.23m.com (Germany) sustains
  # 18-35MB/s on the same file in testing. Checksum verification stays
  # against the canonical source deliberately: a small file (not subject
  # to the same throttling) fetched from a different host than the one
  # serving the bulk bytes, so a compromised/stale mirror still gets
  # caught.
  iso_checksum     = "file:http://download.rockylinux.org/pub/rocky/9/isos/${var.architecture}/CHECKSUM"
  iso_url          = "https://mirror.23m.com/rocky/9/isos/${var.architecture}/Rocky-9-latest-${var.architecture}-boot.iso"
  iso_target_path  = "packer_cache/Rocky-9-latest-${var.architecture}-boot.iso"
  memory           = 2048
  cores            = 4
  qemu_binary      = "qemu-system-${lookup(local.qemu_arch, var.architecture, "")}"
  qemuargs = [
    # -serial stdio only works with a real controlling tty -- when packer
    # runs backgrounded/non-interactive (no tty), the guest's serial
    # console output goes nowhere and there's zero install-progress
    # visibility (confirmed live: an aarch64 build sat for a full hour
    # with no log output at all before timing out). This mirrors the
    # chardev-based logging already used in debian-cloudimg.pkr.hcl: one
    # backend, logged to a plain file AND live-accessible over telnet,
    # regardless of whether a tty is attached.
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4445,server=on,wait=off,telnet=on,logfile=console.log"],
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
    ["-drive", "file=output-rocky9/packer-rocky9,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/Rocky-9-latest-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/rocky9.ks" = templatefile("${path.root}/http/rocky9.ks.pkrtpl.hcl",
      {
        KS_PROXY                 = local.ks_proxy,
        KS_OS_REPOS              = local.ks_os_repos,
        KS_APPSTREAM_REPOS       = local.ks_appstream_repos,
        KS_EXTRAS_REPOS          = local.ks_extras_repos,
        FLEET_USER_PASSWORD_HASH = var.fleet_user_password_hash
      }
    )
  }
}

build {
  sources = ["source.qemu.rocky9"]

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
