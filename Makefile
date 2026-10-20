.PHONY: build app run test restart

build:
	swift build -c release

app: build
	mkdir -p dist/notchtail.app/Contents/MacOS dist/notchtail.app/Contents/Resources
	cp .build/release/notchtail dist/notchtail.app/Contents/MacOS/notchtail
	cp App/Info.plist dist/notchtail.app/Contents/Info.plist
	cp App/Resources/AppIcon.icns dist/notchtail.app/Contents/Resources/AppIcon.icns
	codesign --force --sign - dist/notchtail.app

run:
	swift run notchtail

restart: app
	pkill -x notchtail || true
	sleep 1
	open dist/notchtail.app

test:
	swift run notchtail --self-test
