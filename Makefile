APP := build/HAMenubar.app
ARCHS := --arch arm64 --arch x86_64

.PHONY: app run dist icon clean

app:
	swift build -c release $(ARCHS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release $(ARCHS) --show-bin-path)/HAMenubar" $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	mkdir -p $(APP)/Contents/Resources
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force -s - $(APP)

run: app
	-pkill -x HAMenubar
	open $(APP)

dist: app
	cd build && ditto -c -k --keepParent HAMenubar.app HAMenubar.zip

# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	swift scripts/make-icon.swift build/icon.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) build/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build build
