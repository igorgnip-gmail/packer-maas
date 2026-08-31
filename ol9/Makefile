#!/usr/bin/make -f

include ../scripts/check.mk

PACKER ?= packer
PACKER_LOG ?= 0
TIMEOUT ?= 1h

export PACKER_LOG

# 2026-08-31: switched from legacy BIOS to UEFI (OVMF) -- the target
# fleet this image is deployed onto is UEFI-only, and building under
# legacy BIOS meant anaconda configured a BIOS/MBR bootloader during
# image build regardless of the grub2-efi-x64/shim-x64/efibootmgr
# packages already being installed via %packages, forcing curtin to
# effectively redo bootloader setup at deploy time instead of the image
# already being correct. See ol9.pkr.hcl's own qemuargs comment.
ifeq ($(wildcard /usr/share/OVMF/OVMF_CODE.fd),)
	OVMF_SFX ?= _4M
else
	OVMF_SFX ?=
endif

.PHONY: all clean

all: ol9.tar.gz

$(eval $(call check_packages_deps,ovmf,ovmf))

lint:
	packer validate .
	packer fmt -check -diff .

format:
	packer fmt .

OVMF_VARS.fd: /usr/share/OVMF/OVMF_VARS${OVMF_SFX}.fd
	cp -v $< OVMF_VARS.fd

OVMF_CODE.fd: /usr/share/OVMF/OVMF_CODE${OVMF_SFX}.fd
	cp -v $< OVMF_CODE.fd

ol9.tar.gz: check-deps clean OVMF_VARS.fd OVMF_CODE.fd
	${PACKER} init ol9.pkr.hcl && ${PACKER} build -var timeout=${TIMEOUT} ol9.pkr.hcl

clean:
	${RM} -rf *.fd output-ol9 ol9.tar.gz
