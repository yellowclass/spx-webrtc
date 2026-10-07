#!/bin/bash
# Uploads the packaged artifacts as GitHub release speakx-<ver> on
# yellowclass/spx-webrtc. The fork is public, so the app downloads them
# with no token: Gradle through an ivy repo pattern, CocoaPods through the
# podspec URL (both shown in SPEAKX.md, 'Using it in the app').
#
#   speakx/package.sh && speakx/check_api.sh && speakx/publish.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/build/VERSION"
VER="$WEBRTC_VERSION"
REPO=yellowclass/spx-webrtc
REL="$ROOT/out/release/speakx-$VER"
FILES=(
  "$REL/android-stripped-$VER.aar" "$REL/android-stripped-$VER.pom" "$REL/ivy-$VER.xml"
  "$REL/WebRTC.xcframework.zip" "$REL/WebRTC-SDK.podspec.json"
)
for f in "${FILES[@]}"; do [[ -f "$f" ]] || { echo "missing $f (run speakx/package.sh)"; exit 1; }; done
grep -q "releases/download/speakx-$VER" "$REL/WebRTC-SDK.podspec.json" || { echo "podspec was packaged with --local"; exit 1; }

NOTES="Stripped WebRTC $VER (webrtc $WEBRTC_COMMIT): no AV1/VP9 (+H265 on Android), optimize_for_size.
Built from $(git -C "$ROOT" rev-parse --short HEAD). API check: speakx/check_api.sh passed."
gh release create "speakx-$VER" "${FILES[@]}" -R "$REPO" --title "speakx-$VER" --notes "$NOTES"
