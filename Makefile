# bam — build / install / test / release
#
# bam.xcodeproj is generated from project.yml via XcodeGen, so every target
# regenerates it first to keep the project in sync with source/test folders.

SCHEME      := bam
DERIVED_DEV := .build-dev
DERIVED_REL := .build-rel
RELEASE_APP := $(DERIVED_REL)/Build/Products/Release/bam.app
INSTALL_DIR := /Applications
# System volume forced before relaunch. EAR SAFETY: the audio engine restarts
# on launch and a stuck-high level has hurt before — keep this low.
SAFE_VOLUME := 12

.PHONY: all generate build test install release clean

all: build

## generate: regenerate bam.xcodeproj from project.yml (source of truth)
generate:
	xcodegen generate

## build: debug build of the app
build: generate
	xcodebuild -project bam.xcodeproj -scheme $(SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED_DEV) \
		CODE_SIGNING_ALLOWED=NO build

## test: BamKit unit tests + app/recovery test suite
test: generate
	swift test --package-path BamKit
	xcodebuild -project bam.xcodeproj -scheme $(SCHEME) \
		-configuration Debug -derivedDataPath $(DERIVED_DEV) \
		CODE_SIGNING_ALLOWED=NO test

## install: release build → /Applications, lowering volume before relaunch
install: generate
	xcodebuild -project bam.xcodeproj -scheme $(SCHEME) \
		-configuration Release -derivedDataPath $(DERIVED_REL) build
	@osascript -e 'set volume output volume $(SAFE_VOLUME)'
	-pkill -x bam
	-pkill -x "bam dev"
	rm -rf "$(INSTALL_DIR)/bam.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/bam.app"
	open "$(INSTALL_DIR)/bam.app"

## release: bump version, commit, tag (push triggers the signed Release workflow)
##   usage: make release VERSION=0.5.0
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.5.0"; exit 1; }
	sed -i '' -E 's/MARKETING_VERSION: "[^"]*"/MARKETING_VERSION: "$(VERSION)"/' project.yml
	sed -i '' -E 's/"Version": "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"/"Version": "$(VERSION).0"/' StreamDeck/me.harke.better-audio-mixer.sdPlugin/manifest.json
	$(MAKE) generate
	git add project.yml bam.xcodeproj App/Info.plist StreamDeck/me.harke.better-audio-mixer.sdPlugin/manifest.json
	git commit -m "Release v$(VERSION)"
	git tag -a "v$(VERSION)" -m "bam v$(VERSION)"
	@echo "Tagged v$(VERSION). Push to release: git push origin main --follow-tags"

## clean: remove derived data
clean:
	rm -rf $(DERIVED_DEV) $(DERIVED_REL)
