# OL 10 Packer Template for MAAS

**STATUS: scaffolded but NEVER build-tested.** Copied/adapted from ol9
(structure) and rocky9 (amd64+arm64 handling) as a starting point --
see the `OPEN QUESTIONS` block at the bottom of `ol10.pkr.hcl` for what
still needs verifying (UEK vs RHCK kernel selection on amd64, whether
OL10's kickstart/anaconda syntax is even compatible with what OL9 uses)
before running a real build.

## Introduction

The Packer template in this directory creates an OL 10 AMD64/ARM64
image for use with MAAS. Unlike ol9 (amd64 only), arm64 is supported
here from the start -- but Oracle only publishes a UEK (Unbreakable
Enterprise Kernel) boot ISO for aarch64, no RHCK equivalent, so the two
architectures end up on different default kernel families by design.

## Prerequisites (to create the image)

* A machine running Ubuntu 22.04+ with the ability to run KVM virtual machines.
* qemu-utils, libnbd-bin, nbdkit and fuse2fs
* qemu-system
* qemu-system-modules-spice (if building on Ubuntu 24.04 LTS "Noble")
* ovmf
* [Packer](https://www.packer.io/intro/getting-started/install.html), v1.11.0 or newer

## Requirements (to deploy the image)

* [MAAS](https://maas.io) 3.5+
* [Curtin](https://launchpad.net/curtin) 23.1+

## Customizing the Image

The deployment image may be customized by modifying
`http/ol10.ks.pkrtpl.hcl`. See the [OL kickstart
documentation](https://docs.oracle.com/en/operating-systems/oracle-linux/10/install/)
for more information (link is for OL10 docs generally -- the specific
kickstart-automation page ol9's README links to hadn't been confirmed
to exist yet for OL10 as of this writing).

## Building the image using a proxy

To use a proxy during the installation define the `KS_PROXY` variable in the
environment:

```shell
export KS_PROXY=$HTTP_PROXY
```

## Building an image

```shell
make
```

For arm64:

```shell
make ARCH=aarch64
```

Alternatively, run packer directly (working directory must be
packer-maas/ol10):

```shell
packer init .
PACKER_LOG=1 packer build -var architecture=amd64 .
```

## Setting the local account's console/KVM-fallback password

Not baked into the template. Set `TEMPLATE_USER_PASSWORD_HASH` to a
SHA-512 crypt hash before building if you want the `oraclelinux`
account to have a working local password; otherwise it stays locked
and SSH-key-only (cloud-init still manages SSH keys/sudo normally
either way).

### Makefile Parameters

#### ARCH

Defaults to x86_64 (amd64). Use `ARCH=aarch64` for arm64.

#### TIMEOUT

The timeout to apply when building the image. The default value is set to 1h.

## Uploading an image to MAAS

```shell
maas $PROFILE boot-resources create \
    name='ol/10.2' title='Oracle Linux 10.2' \
    architecture='amd64/generic' filetype='tgz' \
    content@=ol10.tar.gz
```

## Default Username

The default username is ```oraclelinux``` -- passwordless sudo,
key-only SSH by default (see above for optionally giving it a local
password too).
