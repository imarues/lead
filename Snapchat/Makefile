ARCHS = arm64
TARGET = iphone:16.5:14.0
include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = Snap
Snap_FILES = Snap.mm Audio.mm
Snap_CFLAGS = -fobjc-arc -Os -Wno-deprecated-declarations
Snap_CCFLAGS = -std=c++17
Snap_FRAMEWORKS = UIKit Foundation AVFoundation PhotosUI UniformTypeIdentifiers CoreMedia CoreVideo CoreImage AudioToolbox QuartzCore
Snap_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries
include $(THEOS_MAKE_PATH)/library.mk
all::
	@mkdir -p dist
	@cp $(THEOS_OBJ_DIR)/Snap.dylib dist/Snap.dylib
