INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_SCHEME     = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = vcamplus

vcamplus_FILES      = Tweak.xm
vcamplus_CFLAGS     = -fobjc-arc
vcamplus_FRAMEWORKS = AVFoundation CoreMedia CoreVideo Foundation
vcamplus_ARCHS      = arm64 arm64e

include $(THEOS_MAKE_PATH)/tweak.mk
