# SBGamepadProbe — tweak de diagnóstico de la fase 2, SOLO para SpringBoard.

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SBGamepadProbe
SBGamepadProbe_FILES = Tweak.m
SBGamepadProbe_CFLAGS = -fobjc-arc -Wall
SBGamepadProbe_FRAMEWORKS = Foundation CoreFoundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
