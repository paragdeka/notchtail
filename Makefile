.PHONY: build app run test restart signing-cert dmg

# a stable identity keeps Keychain approvals across rebuilds; ad-hoc (-) otherwise.
SIGN_IDENTITY ?= $(shell security find-certificate -c "notchtail local signing" >/dev/null 2>&1 && echo "notchtail local signing" || echo -)
VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
# release builds pass `--arch arm64 --arch x86_64` for a universal binary.
SWIFT_BUILD_FLAGS ?=
# release builds pass `--options runtime --timestamp`, required for notarization.
CODESIGN_FLAGS ?=
BIN_PATH = $(shell swift build -c release $(SWIFT_BUILD_FLAGS) --show-bin-path)

build:
	swift build -c release $(SWIFT_BUILD_FLAGS)

app: build
	rm -rf dist/notchtail.app
	mkdir -p dist/notchtail.app/Contents/MacOS dist/notchtail.app/Contents/Resources
	cp $(BIN_PATH)/notchtail dist/notchtail.app/Contents/MacOS/notchtail
	cp App/Info.plist dist/notchtail.app/Contents/Info.plist
	cp App/Resources/AppIcon.icns dist/notchtail.app/Contents/Resources/AppIcon.icns
	codesign --force $(CODESIGN_FLAGS) --sign "$(SIGN_IDENTITY)" dist/notchtail.app

dmg: SWIFT_BUILD_FLAGS = --arch arm64 --arch x86_64
dmg: app
	rm -rf dist/dmg dist/notchtail-$(VERSION).dmg
	mkdir -p dist/dmg
	cp -R dist/notchtail.app dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname notchtail -srcfolder dist/dmg -ov -format UDZO dist/notchtail-$(VERSION).dmg
	rm -rf dist/dmg

run:
	swift run notchtail

restart: app
	pkill -x notchtail || true
	sleep 1
	open dist/notchtail.app

test:
	swift run notchtail --self-test

signing-cert:
	scripts/create-signing-cert.sh
