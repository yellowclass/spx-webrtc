#!/bin/bash
# Builds in.speakx.webrtc:android:<ver>-<tag>: upstream's published
# io.github.webrtc-sdk:android:<ver> AAR with the Java-only patches in
# speakx/patches/android/ compiled into its classes.jar. The native libraries
# are upstream's, byte for byte, so this needs no WebRTC source sync or build.
#
#   speakx/patch_android_aar.sh p1             # -> out/release/speakx-<ver>-p1/
#   speakx/patch_android_aar.sh p1 --publish   # also uploads GitHub release speakx-<ver>-p1
#
# Before compiling the patched sources it compiles the unpatched ones and
# checks their bytecode equals the published AAR's, so a patch can only ever
# be applied to exactly the code upstream shipped.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/build/VERSION"
TAG="${1:?usage: patch_android_aar.sh <tag e.g. p1> [--publish]}"
VER="$WEBRTC_VERSION"
REV="$VER-$TAG"
REPO=yellowclass/spx-webrtc
OUT="$ROOT/out/release/speakx-$REV"
WORK="$ROOT/out/patch_android_aar"
ANDROID_JAR="$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/platforms/android-*/android.jar | sort -V | tail -1)"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/aar" "$WORK/src" "$WORK/stock" "$WORK/patched" "$OUT"
curl -sfL "https://repo1.maven.org/maven2/io/github/webrtc-sdk/android/$VER/android-$VER.aar" -o "$WORK/upstream.aar"
curl -sfL "https://dl.google.com/dl/android/maven2/androidx/annotation/annotation/1.3.0/annotation-1.3.0.jar" -o "$WORK/annotation.jar"
(cd "$WORK/aar" && unzip -q ../upstream.aar)
CP="$WORK/aar/classes.jar:$ANDROID_JAR:$WORK/annotation.jar"

PATCHES=("$ROOT"/speakx/patches/android/*.patch)
FILES=$(sed -n 's#^+++ b/##p' "${PATCHES[@]}" | sort -u)
for f in $FILES; do
  mkdir -p "$WORK/src/$(dirname "$f")"
  curl -sfL "https://raw.githubusercontent.com/webrtc-sdk/webrtc/$WEBRTC_COMMIT/$f" -o "$WORK/src/$f"
done

javap_all() {  # <class dir> -> normalized disassembly of every class in it
  (cd "$1" && find . -name '*.class' | sort | while read -r c; do
    javap -c -p "$c" | grep -v '^Compiled from' | sed 's/#[0-9]*/#/g'
  done)
}
JAVAC=(javac -nowarn --release 17 -cp "$CP")
SRCS=$(for f in $FILES; do echo "$WORK/src/$f"; done)
"${JAVAC[@]}" -g:none -d "$WORK/stock" $SRCS
(cd "$WORK/stock" && find . -name '*.class' | sed 's#^\./##') > "$WORK/classes.txt"
mkdir -p "$WORK/upstream_classes"
(cd "$WORK/upstream_classes" && unzip -q "$WORK/aar/classes.jar" $(cat "$WORK/classes.txt"))
if ! diff -q <(javap_all "$WORK/stock") <(javap_all "$WORK/upstream_classes") >/dev/null; then
  echo "unpatched sources at $WEBRTC_COMMIT do not match the bytecode in android-$VER.aar"; exit 1
fi

(cd "$WORK/src" && for p in "${PATCHES[@]}"; do patch -s -p1 < "$p"; done)
"${JAVAC[@]}" -g:source,lines -d "$WORK/patched" $SRCS
(cd "$WORK/patched" && zip -q "$WORK/aar/classes.jar" $(find . -name '*.class' | sed 's#^\./##'))
(cd "$WORK/aar" && zip -q -r "$OUT/android-$REV.aar" .)

cat > "$OUT/ivy-$REV.xml" <<IVY
<?xml version="1.0" encoding="UTF-8"?>
<ivy-module version="2.0">
  <info organisation="in.speakx.webrtc" module="android" revision="$REV" status="release"/>
  <configurations><conf name="default"/></configurations>
  <publications><artifact name="android" type="aar" ext="aar" conf="default"/></publications>
</ivy-module>
IVY
echo "built $OUT"; ls -l "$OUT"

if [[ "${2:-}" == "--publish" ]]; then
  NOTES="io.github.webrtc-sdk:android:$VER with these Java patches (native libraries unchanged):
$(for p in "${PATCHES[@]}"; do echo "- $(basename "$p")"; done)
Built by speakx/patch_android_aar.sh from $(git -C "$ROOT" rev-parse --short HEAD)."
  gh release create "speakx-$REV" "$OUT/android-$REV.aar" "$OUT/ivy-$REV.xml" -R "$REPO" --title "speakx-$REV" --notes "$NOTES"
fi
