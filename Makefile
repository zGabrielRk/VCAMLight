THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCAMLight

VCAMLight_FILES = Tweak.xm VCAMOverlay.mm
VCAMLight_CFLAGS = -fobjc-arc
VCAMLight_FRAMEWORKS = UIKit AVFoundation CoreMedia PhotosUI Foundation
VCAMLight_PRIVATE_FRAMEWORKS = AppSupport
VCAMLight_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
