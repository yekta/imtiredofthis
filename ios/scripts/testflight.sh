#!/usr/bin/env bash
# Archives the iOS app for devices and uploads it to TestFlight, with the version
# scripts/release-version.sh gives the commit as both its version and its build. It is signed with
# the Apple Distribution certificate in the keychain and the App Store profiles in
# Resources/Profiles.
#
#   APPLE_API_KEY=… APPLE_API_KEY_ID=… APPLE_API_ISSUER_ID=… ios/scripts/testflight.sh
#
# APPLE_API_KEY is an App Store Connect API key (the .p8's text) that may upload builds. With
# DESTINATION=export, it signs the app into ios/build/export and uploads nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(../scripts/release-version.sh)"
TEAM=44R7KF7645
DESTINATION="${DESTINATION:-upload}"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILES" build

# Installs a profile from Resources/Profiles where Xcode looks, and prints its name.
install_profile() {
    local file="../Resources/Profiles/$1.provisionprofile"
    local plist
    plist="$(security cms -D -i "$file")"
    cp "$file" "$PROFILES/$(plutil -extract UUID raw -o - - <<< "$plist").mobileprovision"
    plutil -extract Name raw -o - - <<< "$plist"
}
APP_PROFILE="$(install_profile routey-ios)"
TUNNEL_PROFILE="$(install_profile routey-ios-tunnel)"
WIDGETS_PROFILE="$(install_profile routey-ios-widgets)"

rm -rf build/Routey.xcarchive build/export
xcodebuild archive -project Routey.xcodeproj -scheme Routey -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/Routey.xcarchive -derivedDataPath build/derived \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" \
    APP_PROFILE="$APP_PROFILE" TUNNEL_PROFILE="$TUNNEL_PROFILE" WIDGETS_PROFILE="$WIDGETS_PROFILE"

cat > build/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DESTINATION</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>provisioningProfiles</key>
    <dict>
        <key>org.routey.routey</key><string>$APP_PROFILE</string>
        <key>org.routey.routey.tunnel</key><string>$TUNNEL_PROFILE</string>
        <key>org.routey.routey.widgets</key><string>$WIDGETS_PROFILE</string>
    </dict>
</dict>
</plist>
PLIST

if [ "$DESTINATION" = export ]; then
    xcodebuild -exportArchive -archivePath build/Routey.xcarchive -exportOptionsPlist build/export.plist \
        -exportPath build/export
    echo "✓ Signed Routey $VERSION into ios/build/export"
    exit 0
fi

KEY="$(mktemp -d)/AuthKey_$APPLE_API_KEY_ID.p8"
echo "$APPLE_API_KEY" > "$KEY"
xcodebuild -exportArchive -archivePath build/Routey.xcarchive -exportOptionsPlist build/export.plist \
    -exportPath build/export -authenticationKeyPath "$KEY" -authenticationKeyID "$APPLE_API_KEY_ID" \
    -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID"
echo "✓ Uploaded Routey $VERSION to TestFlight"
