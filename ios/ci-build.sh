#!/usr/bin/env bash
# Builds an unsigned Dictate.ipa in ios/build/. It is ad-hoc signed with the App Group entitlement only;
# the real signature (certificate and provisioning profile) is applied on the device by a re-signing app.
set -euo pipefail
cd "$(dirname "$0")"

: "${DICTATE_BUNDLE_ID:=app.dictate.ios}"
: "${DICTATE_APP_GROUP:=group.app.dictate.ios}"
: "${DICTATE_VERSION:=0.1}"
: "${DICTATE_BUILD:=1}"

# Drawn by icon.mjs and kept in the repo.
icon=App/Assets.xcassets/AppIcon.appiconset

xcodegen generate --quiet

rm -rf build
xcodebuild -quiet \
  -project Dictate.xcodeproj -scheme Dictate -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/dd \
  CODE_SIGNING_ALLOWED=NO \
  DICTATE_BUNDLE_ID="$DICTATE_BUNDLE_ID" DICTATE_APP_GROUP="$DICTATE_APP_GROUP" \
  MARKETING_VERSION="$DICTATE_VERSION" CURRENT_PROJECT_VERSION="$DICTATE_BUILD" \
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
cp "$icon/icon.png" build/icon.png

# An AltStore-format source next to the ipa: sideloading apps (Feather, AltStore) list it and offer updates.
releases="https://github.com/${GITHUB_REPOSITORY:-owner/dictate-ios}/releases/download/latest"
python3 - "$releases" "$DICTATE_BUNDLE_ID" "$DICTATE_VERSION" "$(stat -f%z build/Dictate.ipa)" > build/source.json <<'EOF'
import datetime, json, sys
releases, bundle, version, size = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
app = {
    "name": "Dictate",
    "bundleIdentifier": bundle,
    "developerName": "Dictate",
    "subtitle": "Push-to-talk dictation keyboard",
    "localizedDescription": "A keyboard with one button: speak, and the text lands in the field.",
    "iconURL": f"{releases}/icon.png",
    "tintColor": "#3478F6",
    "versions": [{
        "version": version,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "downloadURL": f"{releases}/Dictate.ipa",
        "size": size,
    }],
}
print(json.dumps({"name": "Dictate", "identifier": f"{bundle}.source", "apps": [app]}, indent=2))
EOF
ls -l build/Dictate.ipa build/source.json
