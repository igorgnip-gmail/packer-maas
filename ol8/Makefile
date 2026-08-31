#!/usr/bin/make -f

include ../scripts/check.mk

PACKER ?= packer
PACKER_LOG ?= 0
TIMEOUT ?= 1h

export PACKER_LOG

# 2026-08-31: switched from legacy BIOS to UEFI (OVMF) -- see ol9's
# Makefile/ol8.pkr.hcl's own qemuargs comment for why (same fix, same
# root cause). Not yet a live deploy target, but fixed alongside ol9
# for consistency before it becomes one.
ifeq ($(wildcard /usr/share/OVMF/OVMF_CODE.fd),)
	OVMF_SFX ?= _4M
else
	OVMF_SFX ?=
endif

.PHONY: all clean

all: ol8.tar.gz

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

ol8.tar.gz: check-deps clean OVMF_VARS.fd OVMF_CODE.fd
	${PACKER} init ol8.pkr.hcl && ${PACKER} build -var timeout=${TIMEOUT} ol8.pkr.hcl

clean:
	${RM} -rf *.fd output-ol8 ol8.tar.gz
