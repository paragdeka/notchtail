.PHONY: build app run test

build:
	swift build -c release

app: build
	mkdir -p dist/NotchStatus.app/Contents/MacOS dist/NotchStatus.app/Contents/Resources
	cp .build/release/NotchStatus dist/NotchStatus.app/Contents/MacOS/NotchStatus
	cp App/Info.plist dist/NotchStatus.app/Contents/Info.plist
	cp App/Resources/AppIcon.icns dist/NotchStatus.app/Contents/Resources/AppIcon.icns
	codesign --force --sign - dist/NotchStatus.app

run:
	swift run NotchStatus

restart: app
	pkill -x NotchStatus || true
	sleep 1
	open dist/NotchStatus.app

test:
	swift run NotchStatus --self-test
