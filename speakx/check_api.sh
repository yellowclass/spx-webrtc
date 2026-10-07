#!/bin/bash
# Proves a stripped build is a drop-in for upstream's full build of the SAME
# version, and prints the size win. Exits non-zero on any API difference that
# is not on the allow-list below.
#
#   speakx/check_api.sh            # checks whatever is in build/_package
#
# Android: Java classes and JNI exports must be identical (removed codecs keep
#          their JNI entry points and report "unsupported" at runtime).
# iOS:     only the AV1 encoder/decoder classes may disappear, and neither
#          flutter_webrtc nor livekit_client may reference anything removed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/build/VERSION"
VER="$WEBRTC_VERSION"
CACHE="$ROOT/out/upstream/$VER"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE"
FAIL=0
IOS_ALLOWED_REMOVALS='^_OBJC_(META)?CLASS_\$_RTCVideo(En|De)coderAV1$'
# Linking with Apple ld (iOS 27+ SDK, see xcframework_ios.sh) drops lld's exported
# compiler-rt helpers and exports a few more C++ internals. Neither is API the
# plugins use (they compile against the ObjC headers only).
IOS_ALLOWED_REMOVALS="$IOS_ALLOWED_REMOVALS|^___emu(pac|tls)_"
IOS_ALLOWED_ADDITIONS='^__ZN6webrtc'

mb() { awk -v b="$1" 'BEGIN { printf "%.2f", b / 1e6 }'; }
gz() { gzip -9c "$1" | wc -c | tr -d ' '; }
row() { # label full stripped
  local fr fg sr sg
  fr=$(stat -f%z "$2" 2>/dev/null || stat -c%s "$2"); fg=$(gz "$2")
  sr=$(stat -f%z "$3" 2>/dev/null || stat -c%s "$3"); sg=$(gz "$3")
  printf "  %-22s raw %6s -> %6s MB (-%s)   download %5s -> %5s MB (-%s)\n" "$1" \
    "$(mb "$fr")" "$(mb "$sr")" "$(mb $((fr - sr)))" "$(mb "$fg")" "$(mb "$sg")" "$(mb $((fg - sg)))"
}

OUR_AAR="$ROOT/build/_package/android_stripped/libwebrtc.aar"
if [[ -f "$OUR_AAR" ]]; then
  echo "== Android $VER"
  UP_AAR="$CACHE/android-$VER.aar"
  [[ -f "$UP_AAR" ]] || curl -sfLo "$UP_AAR" "https://repo1.maven.org/maven2/io/github/webrtc-sdk/android/$VER/android-$VER.aar" \
    || { echo "  cannot download upstream io.github.webrtc-sdk:android:$VER"; exit 2; }
  mkdir -p "$WORK/up" "$WORK/our"
  (cd "$WORK/up" && unzip -qo "$UP_AAR")
  (cd "$WORK/our" && unzip -qo "$OUR_AAR")
  for side in up our; do
    unzip -Z1 "$WORK/$side/classes.jar" | grep '\.class$' | sort > "$WORK/$side.classes"
  done
  if diff -q "$WORK/up.classes" "$WORK/our.classes" >/dev/null; then
    echo "  Java classes identical ($(wc -l < "$WORK/our.classes" | tr -d ' '))"
  else
    echo "  Java classes DIFFER:"; diff "$WORK/up.classes" "$WORK/our.classes" | sed 's/^/    /'; FAIL=1
  fi
  for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    up="$WORK/up/jni/$abi/libjingle_peerconnection_so.so"
    our="$WORK/our/jni/$abi/libjingle_peerconnection_so.so"
    [[ -f "$our" ]] || { echo "  $abi: missing from our AAR"; FAIL=1; continue; }
    nm -D --defined-only "$up" | awk '{print $3}' | grep '^Java_' | sort > "$WORK/up.jni"
    nm -D --defined-only "$our" | awk '{print $3}' | grep '^Java_' | sort > "$WORK/our.jni"
    if ! diff -q "$WORK/up.jni" "$WORK/our.jni" >/dev/null; then
      echo "  $abi JNI exports DIFFER:"; diff "$WORK/up.jni" "$WORK/our.jni" | sed 's/^/    /'; FAIL=1
    fi
    row "$abi" "$up" "$our"
  done
  echo "  JNI exports identical ($(wc -l < "$WORK/our.jni" | tr -d ' ') per ABI)"
fi

OUR_XCF="$ROOT/build/_package/apple_stripped/WebRTC.xcframework"
if [[ -d "$OUR_XCF" ]]; then
  echo "== iOS $VER"
  UP_ZIP="$CACHE/WebRTC.xcframework.zip"
  [[ -f "$UP_ZIP" ]] || curl -sfLo "$UP_ZIP" "https://github.com/webrtc-sdk/Specs/releases/download/$VER/WebRTC.xcframework.zip" \
    || { echo "  cannot download upstream WebRTC-SDK $VER"; exit 2; }
  (cd "$WORK" && unzip -qo "$UP_ZIP" -d upios)
  up="$(find "$WORK/upios" -path '*ios-arm64/WebRTC.framework/WebRTC' -type f | head -1)"
  our="$OUR_XCF/ios-arm64/WebRTC.framework/WebRTC"
  nm -gU "$up" | awk '{print $3}' | sort > "$WORK/up.sym"
  nm -gU "$our" | awk '{print $3}' | sort > "$WORK/our.sym"
  removed="$(comm -23 "$WORK/up.sym" "$WORK/our.sym")"
  added="$(comm -13 "$WORK/up.sym" "$WORK/our.sym")"
  unexpected="$(grep -vE "$IOS_ALLOWED_REMOVALS" <<<"$removed" | grep -v '^$' || true)"
  echo "  exported symbols $(wc -l < "$WORK/up.sym" | tr -d ' ') -> $(wc -l < "$WORK/our.sym" | tr -d ' ')"
  [[ -n "$removed" ]] && echo "  removed: $(tr '\n' ' ' <<<"$removed")"
  unexpected_added="$(grep -vE "$IOS_ALLOWED_ADDITIONS" <<<"$added" | grep -v '^$' || true)"
  [[ -n "$added" ]] && echo "  added: $(tr '\n' ' ' <<<"$added")"
  if [[ -n "$unexpected" || -n "$unexpected_added" ]]; then
    echo "  UNEXPECTED symbol changes:"; printf '%s\n%s\n' "$unexpected" "$unexpected_added" | sed '/^$/d; s/^/    /'; FAIL=1
  fi
  if ! diff -rq "$(dirname "$up")/Headers" "$(dirname "$our")/Headers" >/dev/null; then
    echo "  public headers differ (expected only for removed AV1 classes):"
    diff -rq "$(dirname "$up")/Headers" "$(dirname "$our")/Headers" | sed 's/^/    /'
  fi
  # Nothing the plugins compile against may be gone.
  names="$(sed -nE 's/^_OBJC_CLASS_\$_(RTC[A-Za-z0-9]+)$/\1/p' <<<"$removed")"
  for n in $names; do
    hits="$(grep -rl "$n" ~/.pub-cache/hosted/pub.dev/flutter_webrtc-*/ios ~/.pub-cache/hosted/pub.dev/flutter_webrtc-*/common \
      ~/.pub-cache/hosted/pub.dev/livekit_client-*/ios ~/.pub-cache/hosted/pub.dev/livekit_client-*/shared_swift 2>/dev/null || true)"
    [[ -n "$hits" ]] && { echo "  $n is still referenced by:"; echo "$hits" | sed 's/^/    /'; FAIL=1; }
  done
  row "ios-arm64" "$up" "$our"
fi

[[ $FAIL -eq 0 ]] && echo "OK: drop-in compatible" || echo "FAILED: see differences above"
exit $FAIL
