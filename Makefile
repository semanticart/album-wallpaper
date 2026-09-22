.PHONY: build run test clean app dist notarize appcast release install

CONFIG ?= debug
APP_NAME := AlbumArtWallpaper
APP_DIR := .build/$(APP_NAME).app
INSTALL_DIR ?= /Applications

# Automation (Music.app AppleEvents) grants are keyed to the app's code-signing
# identity. Ad-hoc signing ("-") produces a new identity on every rebuild, so the
# grant is lost each time and the app keeps asking for permission. If a real
# signing identity is in the keychain, use it: TCC then keys the grant to the
# cert + bundle id, so it persists across rebuilds. Falls back to ad-hoc otherwise.
# "Developer ID Application" wins over other identities: it's the only kind Apple
# accepts for notarization, and using it locally too means dev builds and the
# released app share one TCC grant.
# Override explicitly with `make run CODESIGN_IDENTITY=...` if needed.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk 'match($$0, /[0-9A-F]{40}/) { id = substr($$0, RSTART, RLENGTH); if (!first) first = id; if (/Developer ID Application/) { devid = id; exit } } END { print (devid ? devid : first) }')
ifeq ($(strip $(CODESIGN_IDENTITY)),)
override CODESIGN_IDENTITY := -
endif

# Notarization requires the hardened runtime and a secure timestamp. Ad-hoc
# signatures can't carry a trusted timestamp, so these flags only apply when a
# real identity is used.
ifeq ($(CODESIGN_IDENTITY),-)
CODESIGN_FLAGS :=
else
CODESIGN_FLAGS := --options runtime --timestamp
endif

build:
	swift build -c $(CONFIG)

# `make run` builds a proper .app bundle (icon, menu bar agent, code signature).
# `swift run` also works for day-to-day development, but has no Info.plist, so
# Sparkle stays inert (see Updater.swift) and Music automation grants aren't
# persisted across rebuilds.
#
# Sparkle ships as a prebuilt framework that SwiftPM drops next to the binary;
# the bundle carries it in Contents/Frameworks, where the rpath set in
# Package.swift finds it. Sparkle's copy is only ad-hoc signed, and notarization
# rejects any nested code that isn't Developer ID signed, so its nested pieces
# are re-signed with our identity, innermost first, before the app itself.
SPARKLE_FRAMEWORK := $(APP_DIR)/Contents/Frameworks/Sparkle.framework
SPARKLE_NESTED := \
	Versions/B/XPCServices/Downloader.xpc \
	Versions/B/XPCServices/Installer.xpc \
	Versions/B/Autoupdate \
	Versions/B/Updater.app
app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	mkdir -p "$(APP_DIR)/Contents/Frameworks"
	cp ".build/$(CONFIG)/$(APP_NAME)" "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp -R ".build/$(CONFIG)/Sparkle.framework" "$(APP_DIR)/Contents/Frameworks/"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp Resources/AppIcon.icns Resources/MenuBarIcon.png "$(APP_DIR)/Contents/Resources/"
	for nested in $(SPARKLE_NESTED); do \
		codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(SPARKLE_FRAMEWORK)/$$nested"; \
	done
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(SPARKLE_FRAMEWORK)"
	codesign --force $(CODESIGN_FLAGS) --sign "$(CODESIGN_IDENTITY)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) (signed with: $(CODESIGN_IDENTITY))"

run: app
	pkill -x $(APP_NAME) || true
	sleep 0.5
	open "$(APP_DIR)"

test:
	swift test

clean:
	swift package clean
	rm -rf "$(APP_DIR)"

# Package the release .app into a distributable DMG in .build/dist/. This is what
# the GitHub Releases workflow uploads. VERSION defaults to the Info.plist value
# (CI overrides it with the git tag). The volume gets an /Applications symlink for
# the usual drag-to-install layout, and the DMG itself is signed when a real
# identity is available so it can be notarized (see `make notarize`).
DIST_DIR := .build/dist
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DIST_DMG := $(DIST_DIR)/$(APP_NAME)-$(VERSION).dmg
DMG_STAGING := $(DIST_DIR)/dmg-staging
dist:
	$(MAKE) app CONFIG=release
	mkdir -p "$(DIST_DIR)"
	rm -rf "$(DMG_STAGING)" "$(DIST_DMG)"
	mkdir -p "$(DMG_STAGING)"
	cp -R "$(APP_DIR)" "$(DMG_STAGING)/$(APP_NAME).app"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DIST_DMG)"
	rm -rf "$(DMG_STAGING)"
ifneq ($(CODESIGN_IDENTITY),-)
	codesign --timestamp --sign "$(CODESIGN_IDENTITY)" "$(DIST_DMG)"
endif
	@echo "Wrote $(DIST_DMG)"

# Submit the DMG to Apple's notary service and staple the ticket so Gatekeeper
# accepts it offline, then verify the result. Locally this uses the
# `album-wallpaper-notary` keychain profile; CI overrides NOTARY_ARGS with
# --apple-id/--team-id/--password flags whose values come from repo secrets.
# CI passes them as $$-escaped variable *references*, so the echoed recipe
# shows names, never values — keep this recipe un-@-silenced.
NOTARY_ARGS ?= --keychain-profile album-wallpaper-notary
notarize:
	xcrun notarytool submit "$(DIST_DMG)" $(NOTARY_ARGS) --wait
	xcrun stapler staple "$(DIST_DMG)"
	spctl -a -t open --context context:primary-signature -vv "$(DIST_DMG)"

# Write the Sparkle appcast for the packaged DMG into .build/dist/appcast/.
# The Release workflow attaches it to the GitHub Release, where the app's
# SUFeedURL (Resources/Info.plist) reads it from the stable
# releases/latest/download/appcast.xml URL. generate_appcast mounts the DMG to
# read the version and minimum macOS out of the app, and signs the entry with
# the private EdDSA key — from the login keychain by default (see
# RELEASING.md), or piped in on stdin when CI passes ED_KEY_ARGS='--ed-key-file -'.
# Only the one release is listed: Sparkle needs nothing older, and deltas are
# off since there's no previous archive here to diff against.
APPCAST_DIR := $(DIST_DIR)/appcast
APPCAST := $(APPCAST_DIR)/appcast.xml
SPARKLE_BIN := .build/artifacts/sparkle/Sparkle/bin
ED_KEY_ARGS ?=
appcast: $(SPARKLE_BIN)/generate_appcast
	rm -rf "$(APPCAST_DIR)"
	mkdir -p "$(APPCAST_DIR)"
	cp "$(DIST_DMG)" "$(APPCAST_DIR)/"
	"$(SPARKLE_BIN)/generate_appcast" $(ED_KEY_ARGS) \
		--download-url-prefix "https://github.com/semanticart/album-wallpaper/releases/download/v$(VERSION)/" \
		--link "https://github.com/semanticart/album-wallpaper/releases/latest" \
		--maximum-deltas 0 \
		-o "$(APPCAST)" "$(APPCAST_DIR)"
	@echo "Wrote $(APPCAST)"

# SwiftPM downloads Sparkle's tools alongside the framework on first build.
$(SPARKLE_BIN)/generate_appcast:
	swift build

# Cut a release: stamp VERSION into Info.plist, commit that one file, tag
# vVERSION, and push both — the GitHub Release workflow does the rest (build,
# sign, notarize, publish). Run as `make release VERSION=x.y.z` from main.
# The commit is path-limited to Info.plist, so an otherwise dirty tree is fine.
release:
	@test "$$(git branch --show-current)" = main || \
		{ echo "release must be cut from main (currently on $$(git branch --show-current))"; exit 1; }
	@current=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist); \
		test "$(VERSION)" != "$$current" || \
		{ echo "VERSION=$(VERSION) is already the current version; pass the new one, e.g. make release VERSION=x.y.z"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
		{ echo "VERSION must look like x.y.z (got '$(VERSION)')"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || \
		{ echo "tag v$(VERSION) already exists"; exit 1; }
	@git diff --quiet Resources/Info.plist || \
		{ echo "Resources/Info.plist already has uncommitted changes; commit or revert them first"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	git commit -m "Release $(VERSION)" Resources/Info.plist
	git tag "v$(VERSION)"
	git push origin main "v$(VERSION)"
	@echo "Tagged v$(VERSION) — the Release workflow builds and publishes it from here."

# Build a release app bundle and install it to /Applications, replacing any
# existing copy. Override the destination with `make install INSTALL_DIR=~/Applications`.
install:
	$(MAKE) app CONFIG=release
	pkill -x $(APP_NAME) || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(APP_NAME).app to $(INSTALL_DIR)"
