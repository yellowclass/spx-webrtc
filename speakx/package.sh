#!/bin/bash
# Turns the two stripped build outputs into shippable artifacts:
#   out/maven/in/speakx/webrtc/android-stripped/<ver>/  (aar + pom, a plain Maven layout)
#   out/ios/<ver>/WebRTC.xcframework.zip + WebRTC-SDK.podspec.json (pod name/version match the
#   plugins' 'WebRTC-SDK', '<ver>' pin, so a Podfile override satisfies it)
#   out/release/speakx-<ver>/  exact mirror of the GitHub release publish.sh creates;
#   point the app at file://<repo>/out/release to test before publishing
#
#   speakx/package.sh            # podspec points at the GitHub release (publish.sh)
#   speakx/package.sh --local    # podspec points at the local zip, for a pod install test
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
source "$B/VERSION"
VER="$WEBRTC_VERSION"
RELEASE_URL="https://github.com/yellowclass/spx-webrtc/releases/download/speakx-$VER"
IOS_URL="$RELEASE_URL/WebRTC.xcframework.zip"
[[ "${1:-}" == "--local" ]] && IOS_URL=""

AAR="$B/_package/android_stripped/libwebrtc.aar"
if [[ -f "$AAR" ]]; then
  M="$ROOT/out/maven/in/speakx/webrtc/android-stripped/$VER"
  mkdir -p "$M"
  cp "$AAR" "$M/android-stripped-$VER.aar"
  cat > "$M/android-stripped-$VER.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>in.speakx.webrtc</groupId>
  <artifactId>android-stripped</artifactId>
  <version>$VER</version>
  <packaging>aar</packaging>
  <description>webrtc-sdk $VER without AV1/VP9/H265, optimize_for_size; org.webrtc API</description>
</project>
POM
  # Gradle reads this from the GitHub release (ivy repo in the app). Without it
  # Gradle would assume a .jar, because the plugins declare the dependency
  # without @aar.
  cat > "$M/ivy-$VER.xml" <<IVY
<?xml version="1.0" encoding="UTF-8"?>
<ivy-module version="2.0">
  <info organisation="in.speakx.webrtc" module="android-stripped" revision="$VER" status="release"/>
  <configurations><conf name="default"/></configurations>
  <publications><artifact name="android-stripped" type="aar" ext="aar" conf="default"/></publications>
</ivy-module>
IVY
  (cd "$M" && for f in *.aar *.pom; do shasum -a 1 "$f" | cut -d' ' -f1 > "$f.sha1"; done)
  echo "android: $M"
fi

XCF="$B/_package/apple_stripped/WebRTC.xcframework.zip"
if [[ -f "$XCF" ]]; then
  I="$ROOT/out/ios/$VER"
  mkdir -p "$I"
  cp "$XCF" "$I/WebRTC.xcframework.zip"
  SRC=${IOS_URL:+"\"http\": \"$IOS_URL\""}
  SRC=${SRC:-"\"http\": \"file://$I/WebRTC.xcframework.zip\""}
  cat > "$I/WebRTC-SDK.podspec.json" <<SPEC
{
  "name": "WebRTC-SDK",
  "version": "$VER",
  "summary": "SpeakX stripped WebRTC (no AV1/VP9, optimize_for_size), iOS only.",
  "homepage": "https://github.com/webrtc-sdk/webrtc-build",
  "license": { "type": "BSD", "file": "WebRTC.xcframework/LICENSE" },
  "authors": "SpeakX",
  "platforms": { "ios": "13.0" },
  "source": { $SRC },
  "vendored_frameworks": "WebRTC.xcframework"
}
SPEC
  echo "ios: $I"
fi

REL="$ROOT/out/release/speakx-$VER"
mkdir -p "$REL"
[[ -f "$AAR" ]] && cp "$M/android-stripped-$VER.aar" "$M/android-stripped-$VER.pom" "$M/ivy-$VER.xml" "$REL/"
[[ -f "$XCF" ]] && cp "$I/WebRTC.xcframework.zip" "$I/WebRTC-SDK.podspec.json" "$REL/"
echo "release layout: $REL"
ls "$REL"
