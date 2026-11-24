# GreanCast — command-line build (same project as Xcode: GreanCast.xcodeproj).
#   make            Release build → build/GreanCast.app
#   make run        build and open it
#   make debug      Debug build → build/GreanCast.app
#   make selftest   build, connect to the plugged-in iPhone, measure fps/latency, save a frame
#   make icon       regenerate the app icon (scripts/make-icon.swift)
#   make release    universal build, Developer ID signature, notarization, DMG (scripts/release.sh)
#   make clean

PROJECT       := GreanCast.xcodeproj
SCHEME        := GreanCast
CONFIGURATION ?= Release
DERIVED       := build/DerivedData
APP           := build/GreanCast.app

# Signing: Config/Local.xcconfig wins if present (see Config/Local.xcconfig.example).
# Otherwise, use an "Apple Development" certificate if one is installed (stable identity, so
# macOS keeps the app's permissions across rebuilds), else sign to run locally (ad-hoc).
DEV_CERT      := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}')
ifeq ($(wildcard Config/Local.xcconfig),)
  ifneq ($(DEV_CERT),)
    SIGN_ARGS := CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=$(DEV_CERT)
  endif
endif
SIGN_ARGS     ?=
XCODEBUILD    := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'generic/platform=macOS' -quiet

.PHONY: all run debug selftest icon release clean

all:
	$(XCODEBUILD) -configuration $(CONFIGURATION) $(SIGN_ARGS) $(EXTRA_ARGS) build
	rm -rf $(APP)
	cp -R $(DERIVED)/Build/Products/$(CONFIGURATION)/GreanCast.app $(APP)
	codesign --verify --strict $(APP)
	@echo "Built $(APP) ($(CONFIGURATION))"

run: all
	open $(APP)

debug:
	$(MAKE) all CONFIGURATION=Debug

selftest: all
	$(APP)/Contents/MacOS/GreanCast --selftest /tmp/greancast-selftest.png

icon:
	xcrun swift scripts/make-icon.swift Sources/GreanCast/Assets.xcassets/AppIcon.appiconset

release:
	scripts/release.sh

clean:
	rm -rf build dist
