#!/usr/bin/env bash
# Builds an unsigned Dictate.ipa in ios/build/. It is ad-hoc signed with the App Group entitlement only;
# the real signature (certificate and provisioning profile) is applied on the device by a re-signing app.
set -euo pipefail
cd "$(dirname "$0")"

: "${DICTATE_BUNDLE_ID:=app.dictate.ios}"
: "${DICTATE_APP_GROUP:=group.app.dictate.ios}"

icon=App/Assets.xcassets/AppIcon.appiconset
sips -s format png -Z 1024 ../mac/AppIcon.icns --out "$icon/icon.png" >/dev/null

xcodegen generate --quiet

rm -rf build
xcodebuild -quiet \
  -project Dictate.xcodeproj -scheme Dictate -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO \
  DICTATE_BUNDLE_ID="$DICTATE_BUNDLE_ID" DICTATE_APP_GROUP="$DICTATE_APP_GROUP" \
  build

app=build/dd/Build/Products/Release-iphoneos/Dictate.app
sed "s/DICTATE_APP_GROUP/$DICTATE_APP_GROUP/" Dictate.entitlements > build/Dictate.entitlements
for extension in "$app"/PlugIns/*.appex; do
  codesign --force --sign - --entitlements build/Dictate.entitlements "$extension"
done
codesign --force --sign - --entitlements build/Dictate.entitlements "$app"

mkdir -p build/Payload
cp -R "$app" build/Payload/
(cd build && zip -qry Dictate.ipa Payload)
ls -l build/Dictate.ipa
