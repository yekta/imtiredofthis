#!/usr/bin/env bash
# Builds imtiredofthis.app, with its proxy extension inside, into build/. Needs Xcode 26 or later,
# for the icon.
#
#   scripts/build-app.sh [--open]
#
# VERSION, if set, is the version the app says it is; otherwise scripts/release-version.sh's.
# SIGN_IDENTITY, if set, is the Developer ID certificate the app and the extension are signed with,
# with the hardened runtime that notarizing needs and the provisioning profiles in
# Resources/Profiles, which allow the Network Extension; SIGN_KEYCHAIN, if set, is the keychain it
# is in. Otherwise they are signed ad hoc: the app runs, but macOS won't load the extension.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/imtiredofthis.app"
BUNDLE_ID="com.yekta.imtiredofthis"
PROXY_ID="$BUNDLE_ID.proxy"
TEAM_ID="44R7KF7645"
PROXY="$APP/Contents/Library/SystemExtensions/$PROXY_ID.systemextension"
VERSION="${VERSION:-$(scripts/release-version.sh 2>/dev/null || echo "$(tr -d '[:space:]' < VERSION).0")}"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

echo "▸ Building the app…"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PROXY/Contents/MacOS"
# SwiftPM stamps the binaries as built with the SDK of their deployment target, and macOS then
# draws the app in the old style. Stamping the real SDK gives it the current controls and Liquid Glass.
xcrun vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace \
    -output "$APP/Contents/MacOS/imtiredofthis" "$BIN/imtiredofthis"
xcrun vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace \
    -output "$PROXY/Contents/MacOS/$PROXY_ID" "$BIN/ImtiredofthisProxy"

# The Icon Composer icon becomes Assets.car for macOS 26, and AppIcon.icns for the ones before.
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --target-device mac --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp)" >/dev/null
test -f "$APP/Contents/Resources/Assets.car" && test -f "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>imtiredofthis</string>
    <key>CFBundleDisplayName</key><string>imtiredofthis</string>
    <key>CFBundleExecutable</key><string>imtiredofthis</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

cat > "$PROXY/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>imtiredofthis Proxy</string>
    <key>CFBundleDisplayName</key><string>imtiredofthis</string>
    <key>CFBundleExecutable</key><string>$PROXY_ID</string>
    <key>CFBundleIdentifier</key><string>$PROXY_ID</string>
    <key>CFBundlePackageType</key><string>SYSX</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSSystemExtensionUsageDescription</key><string>Carries the connections of the apps you choose to your Shadowsocks server.</string>
    <key>NetworkExtension</key>
    <dict>
        <key>NEMachServiceName</key><string>$TEAM_ID.$PROXY_ID</string>
        <key>NEProviderClasses</key>
        <dict>
            <key>com.apple.networkextension.app-proxy</key><string>TransparentProxyProvider</string>
        </dict>
    </dict>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
    KEYCHAIN=()
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then KEYCHAIN=(--keychain "$SIGN_KEYCHAIN"); fi
    cp Resources/Profiles/imtiredofthis.provisionprofile "$APP/Contents/embedded.provisionprofile"
    cp Resources/Profiles/imtiredofthis-proxy.provisionprofile "$PROXY/Contents/embedded.provisionprofile"
    codesign --force --options runtime --timestamp ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --sign "$SIGN_IDENTITY" \
        --entitlements Resources/Proxy.entitlements "$PROXY"
    codesign --force --options runtime --timestamp ${KEYCHAIN[@]+"${KEYCHAIN[@]}"} --sign "$SIGN_IDENTITY" \
        --entitlements Resources/App.entitlements "$APP"
else
    codesign --force --sign - "$PROXY" >/dev/null
    codesign --force --sign - "$APP" >/dev/null
fi
echo "✓ Built $APP ($VERSION)"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
