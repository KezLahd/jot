#!/bin/zsh
# Archives Jot and uploads it to TestFlight, so your phone gets it over the internet when you're away from
# the Mac (TestFlight app, automatic updates on). Internal testing needs no review: a build shows up
# 5–15 minutes after upload. Uses the shared App Store Connect API key (see tools/phone.sh).
#
#     tools/testflight.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.appstoreconnect/asc.env
key=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
auth=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
[[ -d JotKit/Frameworks/whisper.xcframework ]] || JotKit/scripts/fetch-whisper.sh
work=build/testflight
rm -rf $work && mkdir -p $work
build=$(date +%Y%m%d%H%M)

print "Archiving build $build…"
xcodebuild -project Jot.xcodeproj -scheme Jot -configuration Release -destination "generic/platform=iOS" \
  -archivePath $work/Jot.xcarchive CURRENT_PROJECT_VERSION=$build -allowProvisioningUpdates "${auth[@]}" archive \
  | grep -E "error:|ARCHIVE" || true
[[ -d $work/Jot.xcarchive ]] || { print "Archive failed."; exit 1; }

cat > $work/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>8QPPD49JQ5</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

print "Signing for the App Store…"
xcodebuild -exportArchive -archivePath $work/Jot.xcarchive -exportPath $work/export \
  -exportOptionsPlist $work/ExportOptions.plist -allowProvisioningUpdates "${auth[@]}" | grep -E "error:|EXPORT" || true
ipa=$(ls $work/export/*.ipa 2>/dev/null | head -1)
[[ -n $ipa ]] || { print "Export failed."; exit 1; }

print "Uploading to TestFlight…"
out=$(xcrun altool --upload-app --type ios --file "$ipa" --apiKey $ASC_KEY_ID --apiIssuer $ASC_ISSUER_ID 2>&1 || true)
print -r -- "$out" | grep -E -i "error|UPLOAD SUCCEEDED|No errors" || true
if print -r -- "$out" | grep -qiE "UPLOAD SUCCEEDED|No errors uploading"; then
  print "Done. Build $build reaches TestFlight once Apple has processed it (usually 5–15 minutes)."
else
  print "Upload failed."; exit 1
fi
