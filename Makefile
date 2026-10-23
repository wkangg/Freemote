ifeq ($(SIDELOADED),1)
MODULES = jailed
endif

TARGET := iphone:clang:latest:12.4
INSTALL_TARGET_PROCESSES = Twitch

ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Freemote

Freemote_FILES = Tweak.xm $(wildcard *.m)
Freemote_CFLAGS = -fobjc-arc
Freemote_LOGOS_DEFAULT_GENERATOR = internal
ifeq ($(SIDELOADED),1)
  CODESIGN_IPA = 0
endif

include $(THEOS_MAKE_PATH)/tweak.mk
