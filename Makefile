INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME     = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus

vcamplus_FILES      = Tweak.xm
vcamplus_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations -Wno-unguarded-availability-new
vcamplus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo Foundation UIKit MobileCoreServices QuartzCore
vcamplus_ARCHS      = arm64 arm64e

include $(THEOS_MAKE_PATH)/tweak.mk
