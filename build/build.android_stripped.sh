#!/bin/bash
# Local build of the non-prefixed stripped AAR (org.webrtc.* API, flutter_webrtc
# drop-in). Runs in a linux/amd64 container because WebRTC only builds for
# Android on an x86_64 Linux host. Source and out/ live in a named volume so a
# failed or interrupted build resumes instead of re-syncing ~30 GB.
#
#   ./build.android_stripped.sh [cpus]
#
# Output: _package/android_stripped/libwebrtc.aar
set -euo pipefail
cd "$(dirname "$0")"
CPUS="${1:-6}"
NAME=speakx-webrtc-android
VOLUME=speakx-webrtc-android-src
OUT="$PWD/_package/android_stripped"
mkdir -p "$OUT"

docker volume create "$VOLUME" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run --name "$NAME" --platform linux/amd64 --cpus="$CPUS" \
  -v "$VOLUME":/root/_source \
  -v "$PWD":/src:ro \
  -v "$OUT":/out \
  -e LC_ALL=C.UTF-8 -e DEBIAN_FRONTEND=noninteractive \
  ubuntu:24.04 bash -c '
    set -ex
    cp -r /src/run.py /src/VERSION /src/.gclient /src/patches /src/scripts /root/
    /root/scripts/apt_install_x86_64.sh >/dev/null
    apt-get install -y openjdk-11-jdk build-essential >/dev/null
    cd /root
    # --webrtc-nobuild skips the four per-arch libwebrtc.a builds; only the AAR
    # (built by build_aar.py) is shipped.
    python3 run.py build android_stripped --webrtc-nobuild
    cp _source/android_stripped/webrtc/src/out/aar/libwebrtc.aar /out/
  '
ls -la "$OUT/libwebrtc.aar"
