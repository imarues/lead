ARCHS = arm64 arm64e
# Opt-in arm64 experiment; keep the existing arm64e build unchanged by default.
ifneq ($(strip $(LEAD_WARP_ARCHIVE)),)
ARCHS = arm64
endif
TARGET = iphone:16.5:14.0
# xz: the default lzma can't be unpacked by RootHidePatcher's dpkg-deb.
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Kira

$(TWEAK_NAME)_FILES = $(shell find Sources \( -name '*.swift' -o -name '*.m' -o -name '*.xm' \))
$(TWEAK_NAME)_SWIFTFLAGS = -ISources/tgapiC/include -Osize
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -ISources/tgapiC/include -Wno-deprecated-declarations -Os
$(TWEAK_NAME)_LDFLAGS = -Wl,-dead_strip
$(TWEAK_NAME)_FRAMEWORKS = CoreServices CoreText CallKit AVFoundation AVKit AudioToolbox CoreMedia CoreVideo CoreImage ImageIO Photos PhotosUI QuartzCore UniformTypeIdentifiers Security
$(TWEAK_NAME)_LIBRARIES = z
ifneq ($(strip $(LEAD_WARP_ARCHIVE)),)
$(TWEAK_NAME)_CFLAGS += -DLEAD_WARP_EXPERIMENTAL=1
$(TWEAK_NAME)_LDFLAGS += "$(abspath $(LEAD_WARP_ARCHIVE))" -lresolv
$(TWEAK_NAME)_FRAMEWORKS += CoreFoundation SystemConfiguration
endif
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal
$(TWEAK_NAME)_RESOURCE_FILES = Sources/tgapi/Resources

# Copy Kira.bundle manually during the packaging step
after-stage::
	@echo ">>> Copying Kira.bundle into .deb package..."
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support/Kira
	@cp -a Kira.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/Kira

include $(THEOS_MAKE_PATH)/tweak.mk

# Also copy the .dylib into packages/ for direct sideload use, and build the
# rootless / RootHide .debs from the same dylib.
after-package::
	@mkdir -p packages
	@cp -f $(THEOS_OBJ_DIR)/Kira.dylib packages/Kira.dylib
	@echo ">>> .dylib copied to packages/Kira.dylib"
	@tools/package_variants.sh
