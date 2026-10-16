#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
if [[ -z "${VR_DEVICE_ID:-}" ]]; then
  DEVICE_JSON="$(mktemp -t vr-devices).json"
  trap 'rm -f "$DEVICE_JSON"' EXIT
  xcrun devicectl list devices --json-output "$DEVICE_JSON" > /dev/null
  VR_DEVICE_ID="$(python3 - "$DEVICE_JSON" <<'PY'
import json,sys
devices=json.load(open(sys.argv[1]))['result']['devices']
phones=[d for d in devices if d.get('hardwareProperties',{}).get('reality')=='physical' and d.get('hardwareProperties',{}).get('productType','').startswith('iPhone')]
if len(phones)!=1:
    sys.exit('Connect one iPhone, or set VR_DEVICE_ID for the intended phone.')
print(phones[0]['hardwareProperties']['udid'])
PY
)"
fi
xcodegen generate --spec project.yml
xcodebuild -project VRPlayer.xcodeproj -scheme VRPlayer -configuration Release -destination "id=$VR_DEVICE_ID" -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
APP="$PWD/build/Build/Products/Release-iphoneos/VRPlayer.app"
xcrun devicectl device install app --device "$VR_DEVICE_ID" "$APP"
mkdir -p dist
rm -rf dist/VRPlayer.app
ditto "$APP" dist/VRPlayer.app
rm -rf build
xcrun devicectl device process launch --device "$VR_DEVICE_ID" --terminate-existing com.mikepearlman.vrplayer.ios
