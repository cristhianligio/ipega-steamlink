# hidprobe — herramienta CLI de diagnóstico HID (fase 2). Se copia a mano al iPad.

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME = hidprobe
hidprobe_FILES = main.m
hidprobe_CFLAGS = -fobjc-arc -Wall
hidprobe_FRAMEWORKS = Foundation CoreFoundation IOKit
hidprobe_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
