#!/bin/bash
# iOS-only variant of xcframework.sh: the SpeakX app ships only on iOS, so the
# macOS / Catalyst / tvOS / visionOS slices are skipped. Same COMMON_ARGS as
# upstream so the only difference from WebRTC-SDK is EXTRA_GN_ARGS.
#
#   xcframework_ios.sh <source_dir> <out_dir> [extra_gn_args]
set -e

SOURCE_DIR="$(realpath "$1")"
OUT_DIR="$(realpath "$2")"
EXTRA_GN_ARGS="${3:-""}"
FRAMEWORK_NAME="WebRTC"
JOBS="${JOBS:-4}"

COMMON_ARGS="
      enable_dsyms = false
      enable_libaom = true
      enable_stripping = true
      ios_enable_code_signing = false
      is_component_build = false
      is_debug = false
      rtc_build_examples = false
      rtc_enable_protobuf = false
      rtc_enable_symbol_export = true
      rtc_include_dav1d_in_internal_decoder_factory = true
      rtc_include_tests = false
      rtc_libvpx_build_vp9 = true
      rtc_use_h264 = false
      treat_warnings_as_errors = true
      use_rtti = true"

PLATFORMS=(
  "iOS-arm64-device:target_os=\"ios\" target_environment=\"device\" target_cpu=\"arm64\" ios_deployment_target=\"13.0\""
  "iOS-arm64-simulator:target_os=\"ios\" target_environment=\"simulator\" target_cpu=\"arm64\" ios_deployment_target=\"13.0\""
  "iOS-x64-simulator:target_os=\"ios\" target_environment=\"simulator\" target_cpu=\"x64\" ios_deployment_target=\"13.0\""
)

cd "$SOURCE_DIR"
for platform_config in "${PLATFORMS[@]}"; do
  platform="${platform_config%%:*}"
  config="${platform_config#*:}"
  echo "=== Building $platform ==="
  gn gen "$OUT_DIR/$platform" --args="$COMMON_ARGS $config $EXTRA_GN_ARGS"
  ninja -C "$OUT_DIR/$platform" ios_framework_bundle -j "$JOBS"
done

mkdir -p "$OUT_DIR/iOS-simulator-lib"
rm -rf "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework" "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
cp -R "$OUT_DIR/iOS-arm64-simulator/$FRAMEWORK_NAME.framework" "$OUT_DIR/iOS-simulator-lib/"
lipo -create -output "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  "$OUT_DIR/iOS-arm64-simulator/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME" \
  "$OUT_DIR/iOS-x64-simulator/$FRAMEWORK_NAME.framework/$FRAMEWORK_NAME"

xcodebuild -create-xcframework \
  -framework "$OUT_DIR/iOS-arm64-device/$FRAMEWORK_NAME.framework" \
  -framework "$OUT_DIR/iOS-simulator-lib/$FRAMEWORK_NAME.framework" \
  -output "$OUT_DIR/$FRAMEWORK_NAME.xcframework"
cp LICENSE "$OUT_DIR/$FRAMEWORK_NAME.xcframework/"
cd "$OUT_DIR" && rm -f "$FRAMEWORK_NAME.xcframework.zip" && zip --symlinks -9 -qr "$FRAMEWORK_NAME.xcframework.zip" "$FRAMEWORK_NAME.xcframework"
