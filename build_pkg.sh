#!/bin/bash
set -e

echo "Building VaultGuard (Release)..."
xattr -rc .
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VaultGuard.xcodeproj -scheme VaultGuard -destination 'platform=macOS,arch=arm64' -configuration Release clean build -quiet

BUILT=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project VaultGuard.xcodeproj -scheme VaultGuard -configuration Release -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)
APP="$BUILT/VaultGuard.app"

if [ ! -d "$APP" ]; then
    echo "ERROR: build product not found at $APP"
    exit 1
fi

echo "Staging for PKG..."
PKG_ROOT="/tmp/vg_pkg_root"
PKG_SCRIPTS="/tmp/vg_pkg_scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT" "$PKG_SCRIPTS"

# Stage the app
cp -R "$APP" "$PKG_ROOT/"

# Create postinstall script
cat << 'EOF' > "$PKG_SCRIPTS/postinstall"
#!/bin/bash
APP_PATH="/Applications/VaultGuard.app"
APPEX_PATH="$APP_PATH/Contents/PlugIns/VaultGuardFinder.appex"
IDENTIFIER="com.vaultguard.finder"

# Determine the console user (not root)
CONSOLE_USER=$(stat -f "%Su" /dev/console)

if [ "$CONSOLE_USER" = "root" ] || [ -z "$CONSOLE_USER" ]; then
    echo "Could not identify console user."
    exit 0
fi

# 1. Ignore existing plugin versions if any
sudo -u "$CONSOLE_USER" pluginkit -e ignore -i "$IDENTIFIER" 2>/dev/null || true

# 2. Add and elect the new plugin
sudo -u "$CONSOLE_USER" pluginkit -a "$APPEX_PATH"
sudo -u "$CONSOLE_USER" pluginkit -e use -i "$IDENTIFIER"

# 3. Restart Finder to load it
sudo -u "$CONSOLE_USER" killall Finder || true

# 4. Open the main app so it initializes the App Group before user tries context menu
sudo -u "$CONSOLE_USER" open "$APP_PATH"

exit 0
EOF

chmod +x "$PKG_SCRIPTS/postinstall"

echo "Building PKG..."
rm -f VaultGuard.pkg
pkgbuild --root "$PKG_ROOT" \
         --scripts "$PKG_SCRIPTS" \
         --identifier "com.vaultguard.installer" \
         --version "1.0" \
         --install-location "/Applications" \
         VaultGuard.pkg -q

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
echo "✅ Created VaultGuard.pkg"
