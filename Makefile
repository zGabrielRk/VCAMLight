THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMLight

VCAMLight_FILES = Tweak.xm VCAMOverlay.mm
VCAMLight_CFLAGS = -fobjc-arc -fno-modules
VCAMLight_FRAMEWORKS = UIKit AVFoundation CoreMedia CoreVideo PhotosUI Foundation
VCAMLight_LIBRARIES = substrate

ADDITIONAL_CFLAGS = -fno-modules

include $(THEOS_MAKE_PATH)/tweak.mk
