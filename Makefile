ifeq ($(SIDELOADED),1)
MODULES = jailed
endif

TARGET := iphone:clang:latest:12.4
INSTALL_TARGET_PROCESSES = Twitch

ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Freemote

# Tag the control file's version with the commit, e.g. 1.0.0+d1311b9 (used for both the deb and the IPA)
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)
PACKAGE_VERSION := $(shell grep -i '^Version:' control | cut -d' ' -f2)$(if $(GIT_COMMIT),+$(GIT_COMMIT))

Freemote_FILES = Tweak.x $(wildcard *.m)
Freemote_CFLAGS = -fobjc-arc -DFREEMOTE_VERSION='"$(PACKAGE_VERSION)"'
Freemote_FRAMEWORKS = UIKit
Freemote_LOGOS_DEFAULT_GENERATOR = internal
ifeq ($(SIDELOADED),1)
  CODESIGN_IPA = 0
endif

include $(THEOS_MAKE_PATH)/tweak.mk
