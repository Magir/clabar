APP         = build/Clabar.app
BINARY      = .build/release/Clabar
BUNDLE      = .build/release/Clabar_Clabar.bundle
APP_VERSION ?= 0.0.0-dev
# Release builds pass SU_FEED_URL and SPARKLE_PUB_KEY to enable auto-updates.

.PHONY: app run test clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Frameworks
	cp bundle/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(APP_VERSION)" $(APP)/Contents/Info.plist
	@if [ -n "$(SU_FEED_URL)" ]; then plutil -replace SUFeedURL -string "$(SU_FEED_URL)" $(APP)/Contents/Info.plist; fi
	@if [ -n "$(SPARKLE_PUB_KEY)" ]; then plutil -replace SUPublicEDKey -string "$(SPARKLE_PUB_KEY)" $(APP)/Contents/Info.plist; fi
	cp $(BINARY) $(APP)/Contents/MacOS/Clabar
	cp bundle/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	if [ -d "$(BUNDLE)" ]; then cp -R "$(BUNDLE)" $(APP)/Contents/Resources/; fi
	@FW=$$(find .build/artifacts -type d -name Sparkle.framework 2>/dev/null | head -1); \
	if [ -n "$$FW" ]; then cp -R "$$FW" $(APP)/Contents/Frameworks/; else echo "warning: Sparkle.framework not found"; fi
	codesign --force --deep --sign - $(APP)
	@echo "Built $(APP) ($(APP_VERSION))"

run: app
	open $(APP)

test:
	swift test

clean:
	rm -rf .build build
