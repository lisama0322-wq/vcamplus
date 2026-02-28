INSTALL_TARGET_PROCESSES = SpringBoard                                                                                  THEOS_PACKAGE_SCHEME     = rootless
TARGET                   = iphone:clang:16.5:14.0                                                                     
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus

vcamplus_FILES      = Tweak.xm
vcamplus_CFLAGS     = -fobjc-arc -Wno-deprecated-declarations
vcamplus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo Foundation UIKit MobileCoreServices
vcamplus_ARCHS      = arm64 arm64e

include $(THEOS_MAKE_PATH)/tweak.mk
