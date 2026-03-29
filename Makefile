XCODE   := /Applications/Xcode.app/Contents/Developer
PROJECT := VaultGuard.xcodeproj
SCHEME  := VaultGuard
DEST    := platform=macOS,arch=arm64
CONFIG  ?= Debug
XBUILD  := DEVELOPER_DIR=$(XCODE) xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination $(DEST) -configuration $(CONFIG) -allowProvisioningUpdates

# ── Main targets ──────────────────────────────────────────────────────────────

.PHONY: build run test clean open logs ext dmg pkg

## build   — compile both app and Finder extension
build:
	@xattr -rc .
	$(XBUILD) build 2>&1 | grep -E "error:|warning:|BUILD"; exit $${PIPESTATUS[0]}

## test    — build and run all automated tests
test:
	$(XBUILD) test | grep -E "Test (Suite|Case)|passed|failed|skipped|error:"

## clean   — kill processes, remove /Applications install, wipe derived data
clean:
	@pkill -f VaultGuard 2>/dev/null; echo "Processes stopped."
	@pluginkit -e ignore -i com.vaultguard.finder 2>/dev/null; echo "Extension disabled."
	@rm -rf /Applications/VaultGuard.app && echo "Removed /Applications/VaultGuard.app." || echo "Nothing in /Applications to remove."
	@$(XBUILD) clean -quiet
	@echo "Clean complete."

## open    — open the project in Xcode
open:
	open $(PROJECT)

_install:
	@BUILT=$$(DEVELOPER_DIR=$(XCODE) xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -configuration $(CONFIG) -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $$3}' | head -1); \
	if [ ! -d "$$BUILT/VaultGuard.app" ]; then echo "ERROR: build product not found at $$BUILT/VaultGuard.app — did the build succeed?"; exit 1; fi; \
	pkill -f VaultGuard 2>/dev/null; sleep 0.5; \
	rm -rf /Applications/VaultGuard.app; \
	cp -R "$$BUILT/VaultGuard.app" /Applications/VaultGuard.app; \
	echo "Installed $(CONFIG) build to /Applications/VaultGuard.app"

## run     — build, install to /Applications, and launch
run: build _install
	open /Applications/VaultGuard.app

## logs    — stream VaultGuard logs in real time (Ctrl-C to stop)
logs:
	log stream --predicate 'subsystem == "com.vaultguard" OR subsystem == "com.vaultguard.finder"' --level debug

## ext     — install to /Applications, register Finder extension, relaunch Finder
ext: build _install
	@pluginkit -e ignore -i com.vaultguard.finder 2>/dev/null; \
	pluginkit -a /Applications/VaultGuard.app/Contents/PlugIns/VaultGuardFinder.appex; \
	pluginkit -e use -i com.vaultguard.finder; \
	killall Finder; \
	sleep 1; \
	open /Applications/VaultGuard.app; \
	echo "Done — right-click any folder in Finder to test."

## help    — show this list
help:
	@grep -E '^##' Makefile | sed 's/## /  make /'

## pkg     — build Release version and package into VaultGuard.pkg installer
pkg:
	@chmod +x build_pkg.sh
	@./build_pkg.sh
