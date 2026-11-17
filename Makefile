APP := build/HAMenubar.app
ARCHS := --arch arm64 --arch x86_64

.PHONY: app run dist clean

app:
	swift build -c release $(ARCHS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$(swift build -c release $(ARCHS) --show-bin-path)/HAMenubar" $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign --force -s - $(APP)

run: app
	-pkill -x HAMenubar
	open $(APP)

dist: app
	cd build && ditto -c -k --keepParent HAMenubar.app HAMenubar.zip

clean:
	rm -rf .build build
