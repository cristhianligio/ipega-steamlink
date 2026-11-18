# ICadeSteamLink — fase 1: convierte el teclado iCade del iPega PG-9083 en un
# mando virtual de SDL3 dentro de Steam Link.

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ICadeSteamLink
ICadeSteamLink_FILES = Tweak.m
ICadeSteamLink_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
ICadeSteamLink_FRAMEWORKS = Foundation UIKit GameController

include $(THEOS_MAKE_PATH)/tweak.mk
