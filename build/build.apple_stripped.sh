#!/bin/bash
# Non-prefixed stripped WebRTC.xcframework (RTC* ObjC names, module "WebRTC"),
# a drop-in for the WebRTC-SDK pod that flutter_webrtc / livekit_client pin.
# Same codec cuts as upstream's apple_prefixed_stripped, without apple_prefix.patch.
#
#   JOBS=4 ./build.apple_stripped.sh
#
# Output: _package/apple_stripped/WebRTC.xcframework(.zip)
set -e
cd "$(dirname "$0")"
python3 run.py build apple --webrtc-fetch

export PATH="$PWD/_source/apple/depot_tools:$PATH"
mkdir -p _package/apple_stripped
# H265 stays: VideoToolbox-backed on Apple (no size win) and rtc_use_h265=false
# does not build the ObjC factories (upstream note).
STRIPPED_GN_ARGS="
      enable_libaom = false
      rtc_include_dav1d_in_internal_decoder_factory = false
      rtc_libvpx_build_vp9 = false
      optimize_for_size = true"
. apple/xcframework_ios.sh _source/apple/webrtc/src _package/apple_stripped "$STRIPPED_GN_ARGS"
