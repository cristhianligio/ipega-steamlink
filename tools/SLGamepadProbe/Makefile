# SLGamepadProbe — diagnóstico de la fase 2 alojado en Steam Link.

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SLGamepadProbe
SLGamepadProbe_FILES = Tweak.m
SLGamepadProbe_CFLAGS = -fobjc-arc -Wall
SLGamepadProbe_FRAMEWORKS = Foundation CoreFoundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
