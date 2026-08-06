APP      = build/Clabar.app
BINARY   = .build/release/Clabar
BUNDLE   = .build/release/Clabar_Clabar.bundle

.PHONY: app run test clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	cp $(BINARY) $(APP)/Contents/MacOS/Clabar
	if [ -d $(BUNDLE) ]; then cp -R $(BUNDLE) $(APP)/Contents/Resources/; fi
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP)"

run: app
	open $(APP)

test:
	swift test

clean:
	rm -rf .build build
