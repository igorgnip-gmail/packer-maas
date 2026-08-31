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

variable "ol9_iso_url" {
  type    = string
  default = "https://yum.oracle.com/ISOS/OracleLinux/OL9/u2/x86_64/OracleLinux-R9-U2-x86_64-boot.iso"
}

variable "ol9_sha256sum_path" {
  type    = string
  default = "https://linux.oracle.com/security/gpg/checksum/OracleLinux-R9-U2-Server-x86_64.checksum"
}

# use can use "--url" to specify the exact url for os repo
variable "ks_os_repos" {
  type    = string
  default = "--url='https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/x86_64'"
}

# Use --baseurl to specify the exact url for AppStream repo
variable "ks_appstream_repos" {
  type    = string
  default = "--baseurl='https://yum.oracle.com/repo/OracleLinux/OL9/appstream/x86_64/'"
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

source "qemu" "ol9" {
  boot_command = ["<up><tab> ", "inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ol9.ks ", "console=ttyS0 inst.cmdline", "<enter>"]
  boot_wait    = "3s"
  communicator = "none"
  disk_size    = "4G"
  headless     = true
  iso_checksum = "file:${var.ol9_sha256sum_path}"
  iso_url      = var.ol9_iso_url
  memory       = 2048
  # See rocky9.pkr.hcl for why: -serial stdio produces zero output when
  # packer runs backgrounded/non-interactive (no controlling tty). Note:
  # this template has no architecture/host_is_arm variable at all --
  # amd64 (-cpu host) only, unlike rocky9/alma8/alma9.
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
  qemuargs = [
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4448,server=on,wait=off,telnet=on,logfile=console.log"],
    ["-serial", "chardev:consolesock"],
    ["-machine", "accel=kvm"],
    ["-cpu", "host"],
    ["-global", "driver=cfi.pflash01,property=secure,value=off"],
    ["-drive", "if=pflash,format=raw,unit=0,id=ovmf_code,readonly=on,file=OVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,unit=1,id=ovmf_vars,file=OVMF_VARS.fd"]
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
