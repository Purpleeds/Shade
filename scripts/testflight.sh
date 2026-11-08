#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${APPLE_TEAM_ID:?Set the verified Apple Developer team ID}"
: "${BUILD_NUMBER:?Set an unused numeric build number}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid build number"; exit 1; }
export APPLE_TEAM_ID BUILD_NUMBER
XCODEGEN="${XCODEGEN:-xcodegen}"
"$XCODEGEN" generate
mkdir -p build/testflight
auth=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  : "${ASC_KEY_ID:?Set ASC_KEY_ID}" "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"
  test -r "$ASC_KEY_PATH"
  auth+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -project Shade.xcodeproj -scheme Shade -configuration Release   -destination 'generic/platform=iOS' -archivePath build/testflight/Shade.xcarchive   "${auth[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID"   CODE_SIGN_STYLE=Automatic CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive   2>&1 | tee build/testflight/archive.log
codesign --verify --deep --strict build/testflight/Shade.xcarchive/Products/Applications/Shade.app
python3 - <<'PYEXPORT'
import os, plistlib
with open('build/testflight/ExportOptions.plist','wb') as f:
    plistlib.dump({'method':'app-store-connect','destination':'export',
      'teamID':os.environ['APPLE_TEAM_ID'],'signingStyle':'automatic',
      'manageAppVersionAndBuildNumber':False,'uploadSymbols':True},f)
PYEXPORT
xcodebuild -exportArchive -archivePath build/testflight/Shade.xcarchive   -exportOptionsPlist build/testflight/ExportOptions.plist -exportPath build/testflight/export   "${auth[@]}" 2>&1 | tee build/testflight/export.log
mkdir -p build/testflight/verify
IPA=$(find build/testflight/export -maxdepth 1 -name '*.ipa' -print -quit)
test -n "$IPA"
ditto -x -k "$IPA" build/testflight/verify
APP=build/testflight/verify/Payload/Shade.app
codesign --verify --deep --strict "$APP"
security cms -D -i "$APP/embedded.mobileprovision" > build/testflight/profile.plist
codesign -d --entitlements :- "$APP" > build/testflight/entitlements.plist 2>/dev/null
python3 - <<'PYVERIFY'
import os, plistlib
from pathlib import Path
load=lambda p: plistlib.loads(Path(p).read_bytes())
p=load('build/testflight/profile.plist')
e=load('build/testflight/entitlements.plist')
i=load('build/testflight/verify/Payload/Shade.app/Info.plist')
assert i['CFBundleIdentifier']=='com.shadeapp.shade'
assert i['CFBundleVersion']==os.environ['BUILD_NUMBER']
assert os.environ['APPLE_TEAM_ID'] in p['TeamIdentifier']
assert not p.get('ProvisionedDevices') and not p.get('ProvisionsAllDevices')
assert not e.get('get-task-allow',False)
assert e['application-identifier'].endswith('.com.shadeapp.shade')
assert Path('build/testflight/verify/Payload/Shade.app/PrivacyInfo.xcprivacy').exists()
print('Verified exported App Store IPA, bundle ID, build number, team and entitlements.')
PYVERIFY
python3 - <<'PYUPLOAD'
import plistlib
p='build/testflight/ExportOptions.plist'
with open(p,'rb') as f: d=plistlib.load(f)
d['destination']='upload'
with open(p,'wb') as f: plistlib.dump(d,f)
PYUPLOAD
xcodebuild -exportArchive -archivePath build/testflight/Shade.xcarchive   -exportOptionsPlist build/testflight/ExportOptions.plist -exportPath build/testflight/upload   "${auth[@]}" 2>&1 | tee build/testflight/upload.log
echo 'Upload completed. Apple processing and TestFlight availability still require confirmation in App Store Connect.'
