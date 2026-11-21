ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstaFakeCam
InstaFakeCam_FILES = Sources/InstaFakeCam.xm
InstaFakeCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Os
InstaFakeCam_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia CoreVideo CoreImage PhotosUI UniformTypeIdentifiers QuartzCore
InstaFakeCam_LIBRARIES = substrate
InstaFakeCam_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

after-stage::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries
