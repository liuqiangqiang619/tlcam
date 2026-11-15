ARCHS = arm64
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TLCam
TLCam_FILES = Tweak.m IMUSynth.m
TLCam_FRAMEWORKS = Foundation UIKit AVFoundation CoreVideo CoreImage CoreGraphics Vision CoreMotion
TLCam_LIBRARIES = pthread
TLCam_CFLAGS = -fobjc-arc -O2
TLCam_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/tweak.mk
