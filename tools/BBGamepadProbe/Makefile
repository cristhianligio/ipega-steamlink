# BBGamepadProbe — tweak de diagnóstico de la fase 2, SOLO para backboardd.
# Se copia a mano al iPad (no es para uso normal).

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BBGamepadProbe
BBGamepadProbe_FILES = Tweak.m
BBGamepadProbe_CFLAGS = -fobjc-arc -Wall
BBGamepadProbe_FRAMEWORKS = Foundation CoreFoundation IOKit

include $(THEOS_MAKE_PATH)/tweak.mk
