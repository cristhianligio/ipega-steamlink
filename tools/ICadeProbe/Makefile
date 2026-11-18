# ICadeProbe: tweak de diagnóstico. Solo REGISTRA (no modifica) los eventos de
# teclado y de mandos que SDL3 entrega a Steam Link, para descubrir qué letras
# envía el control en modo iCade.

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ICadeProbe
ICadeProbe_FILES = Tweak.m
ICadeProbe_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter
ICadeProbe_FRAMEWORKS = Foundation UIKit GameController

include $(THEOS_MAKE_PATH)/tweak.mk
