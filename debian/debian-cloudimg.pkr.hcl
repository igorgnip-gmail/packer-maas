locals {
  qemu_arch = {
    "amd64" = "x86_64"
    "arm64" = "aarch64"
  }
  qemu_machine = {
    "amd64" = "accel=kvm"
    "arm64" = var.host_is_arm ? "virt,accel=kvm" : "virt"
  }
  qemu_cpu = {
    "amd64" = "host"
    # "max" under aarch64 TCG (no KVM, cross-building on an x86_64 host)
    # emulates an enormous/exotic feature set that's extremely slow to
    # translate -- confirmed live on the RHEL-family templates: over an
    # hour with zero boot progress vs. under 30s to a working GRUB menu
    # with cortex-a72. Applying the same fix here pre-emptively before
    # ever attempting a debian13 arm64 build. host_is_arm=true (real ARM
    # hardware) keeps "host" passthrough, untouched.
    "arm64" = var.host_is_arm ? "host" : "cortex-a72"
  }

  proxy_env = [
    "http_proxy=${var.http_proxy}",
    "https_proxy=${var.https_proxy}",
    "no_proxy=${var.https_proxy}",
  ]
}

source "null" "dependencies" {
  communicator = "none"
}

source "qemu" "cloudimg" {
  boot_wait      = "2s"
  cpus           = 2
  disk_image     = true
  disk_size      = "4G"
  format         = "qcow2"
  headless       = var.headless
  http_directory = var.http_directory
  iso_checksum   = "file:http://cloud.debian.org/images/cloud/${var.debian_series}/daily/latest/SHA512SUMS"
  iso_url        = "http://cloud.debian.org/images/cloud/${var.debian_series}/daily/latest/debian-${var.debian_version}-generic-${var.architecture}-daily.qcow2"
  memory         = 2048
  qemu_binary    = "qemu-system-${lookup(local.qemu_arch, var.architecture, "")}"
  qemu_img_args {
    create = ["-F", "qcow2"]
  }
  qemuargs = [
    ["-machine", "${lookup(local.qemu_machine, var.architecture, "")}"],
    ["-cpu", "${lookup(local.qemu_cpu, var.architecture, "")}"],
    ["-device", "virtio-gpu-pci"],
    ["-drive", "if=pflash,format=raw,id=ovmf_code,readonly=on,file=OVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,id=ovmf_vars,file=OVMF_VARS.fd"],
    ["-drive", "file=output-cloudimg/packer-cloudimg,format=qcow2"],
    ["-drive", "file=seeds-cloudimg.iso,format=raw"],
    # Guest serial console -> a chardev that is BOTH logged to a plain
    # file (mandatory, so a failed/hung build always leaves a trail even
    # with nobody watching live) AND live-accessible over telnet
    # (secondary access requested: `telnet localhost 4444` while a build
    # is running). One chardev, not two separate -serial invocations --
    # qemu supports both in the same backend. server=on,wait=off so qemu
    # itself doesn't block waiting for a telnet client to attach; the
    # build proceeds normally whether or not anyone ever connects.
    # Debian's official cloud images already enable a ttyS0 serial
    # console by default (standard for cloud-init images across every
    # major cloud provider) -- unlike an ISO/preseed install, no
    # extra console=ttyS0 boot_command injection should be needed here,
    # but the log will simply be empty if that assumption turns out
    # wrong, which is itself the confirmation either way.
    ["-chardev", "socket,id=consolesock,host=127.0.0.1,port=4444,server=on,wait=off,telnet=on,logfile=console.log"],
    ["-serial", "chardev:consolesock"]
  ]
  shutdown_command       = "sudo -S shutdown -P now"
  ssh_handshake_attempts = 50
  ssh_password           = var.ssh_password
  ssh_timeout            = var.timeout
  ssh_username           = var.ssh_username
  ssh_wait_timeout       = var.timeout
  use_backing_file       = true
}

build {
  name    = "cloudimg.deps"
  sources = ["source.null.dependencies"]

  provisioner "shell-local" {
    inline = [
      "cloud-localds seeds-cloudimg.iso user-data-cloudimg meta-data"
    ]
    inline_shebang = "/bin/bash -e"
  }
}

build {
  name    = "cloudimg.image"
  sources = ["source.qemu.cloudimg"]

  provisioner "shell" {
    environment_vars = concat(local.proxy_env, ["DEBIAN_FRONTEND=noninteractive", "DEBIAN_VERSION=${var.debian_version}", "BOOT_MODE=${var.boot_mode}"])
    scripts          = ["${path.root}/scripts/essential-packages.sh", "${path.root}/scripts/setup-boot.sh", "${path.root}/scripts/networking.sh"]
  }

  provisioner "shell" {
    environment_vars  = concat(local.proxy_env, ["DEBIAN_FRONTEND=noninteractive"])
    expect_disconnect = true
    scripts           = [var.customize_script]
  }

  provisioner "shell" {
    environment_vars = [
      "CLOUDIMG_CUSTOM_KERNEL=${var.kernel}",
      "DEBIAN_FRONTEND=noninteractive"
    ]
    scripts = ["${path.root}/scripts/install-custom-kernel.sh"]
  }

  provisioner "file" {
    destination = "/tmp/"
    sources     = ["${path.root}/scripts/curtin-hooks"]
  }

  provisioner "shell" {
    environment_vars = ["CLOUDIMG_CUSTOM_KERNEL=${var.kernel}"]
    scripts          = ["${path.root}/scripts/setup-curtin.sh"]
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    scripts          = ["${path.root}/scripts/cleanup.sh"]
  }

  post-processor "shell-local" {
    inline = [
      "IMG_FMT=qcow2",
      "SOURCE=cloudimg",
      "ROOT_PARTITION=1",
      "OUTPUT=${var.filename}",
      "source ../scripts/fuse-nbd",
      "source ../scripts/fuse-tar-root"
    ]
    inline_shebang = "/bin/bash -e"
  }
}
