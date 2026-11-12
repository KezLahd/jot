#!/bin/zsh
# Builds Jot (Release) and installs it on your iPhone over Wi-Fi.
# Signs through the shared App Store Connect API key so Xcode can make or renew profiles (iCloud, App Group,
# the share extension) without an Apple ID signed in to Xcode.
#
#     tools/phone.sh            build and install
#     tools/phone.sh build      build only
#
# The key stays outside the repo: ~/.appstoreconnect/asc.env (ASC_KEY_ID, ASC_ISSUER_ID) and
# ~/.appstoreconnect/private_keys/AuthKey_<KEY ID>.p8. Needs JotKit/Frameworks (JotKit/scripts/fetch-whisper.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
# Your device id (xcrun devicectl list devices) goes in JOT_PHONE or tools/.phone, which git ignores.
PHONE=${JOT_PHONE:-$(cat tools/.phone 2>/dev/null || true)}
[[ -n $PHONE || ${1:-} == build ]] || { echo "Put your device id in tools/.phone or JOT_PHONE."; exit 1; }
[[ -d JotKit/Frameworks/whisper.xcframework ]] || JotKit/scripts/fetch-whisper.sh
auth=()
env=~/.appstoreconnect/asc.env
if [[ -f $env ]]; then
  source $env
  key=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
  [[ -f $key ]] || { echo "No key file at $key"; exit 1; }
  auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
else
  echo "No asc.env: signing with the profiles Xcode already has."
fi
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Release -destination "generic/platform=iOS" \
  -derivedDataPath build/phone -allowProvisioningUpdates "${auth[@]}" build 2>&1 | grep -E "error|BUILD" | head -20
[[ -d build/phone/Build/Products/Release-iphoneos/Jot.app ]] || { echo "Build failed."; exit 1; }
[[ ${1:-} == build ]] && exit 0
xcrun devicectl device install app --device $PHONE build/phone/Build/Products/Release-iphoneos/Jot.app 2>&1 | grep -iE "installed|error"
