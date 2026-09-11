#!/usr/bin/make -f

include ../scripts/check.mk

PACKER ?= packer
PACKER_LOG ?= 0
TIMEOUT ?= 1h
ARCH ?= x86_64

# Detect if running on ARM host
ifeq ($(shell uname -m),aarch64)
    HOST_IS_ARM = true
else
    HOST_IS_ARM = false
endif

ifeq ($(wildcard /usr/share/OVMF/OVMF_CODE.fd),)
	OVMF_SFX ?= _4M
else
	OVMF_SFX ?=
endif

export PACKER_LOG

# Fallback -- ol8.pkr.hcl's own variable "architecture" expects
# amd64/arm64 (not x86_64/aarch64), matching rocky8/ol9's convention.
ifeq ($(strip $(ARCH)),x86_64)
	ARCH = amd64
endif
ifeq ($(strip $(ARCH)),aarch64)
	ARCH = arm64
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
	cp -v $< $(if $(filter arm64,$(ARCH)),aarch64,x86_64)_VARS.fd

SIZE_VARS.fd:
ifeq ($(strip $(ARCH)),arm64)
	truncate -s 64m aarch64_VARS.fd
else
	truncate -s 2m x86_64_VARS.fd
endif

ol8.tar.gz: check-deps clean OVMF_VARS.fd SIZE_VARS.fd
	${PACKER} init ol8.pkr.hcl && ${PACKER} build \
		-var architecture=${ARCH} \
		-var host_is_arm=${HOST_IS_ARM} \
		-var timeout=${TIMEOUT} \
		-var ovmf_suffix=${OVMF_SFX} \
		ol8.pkr.hcl

clean:
	${RM} -rf *.fd output-ol8 ol8.tar.gz
