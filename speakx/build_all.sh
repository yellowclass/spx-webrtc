#!/bin/bash
# Builds iOS and Android without overlapping their source syncs: googlesource
# rate-limits one IP (HTTP 429), and two full syncs at once trip it. iOS syncs
# first; Android starts syncing once iOS has moved on to compiling, so the two
# compiles overlap but the downloads never do. Each build retries 3 times (a
# rerun resumes the sync; Android retries inside its container).
#
#   speakx/build_all.sh
#
# Env: GCLIENT_JOBS (default 3), IOS_JOBS (default 3), ANDROID_CPUS (default 6),
#      LOG_DIR (default out/logs).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export GCLIENT_JOBS="${GCLIENT_JOBS:-3}"
IOS_JOBS="${IOS_JOBS:-3}"
ANDROID_CPUS="${ANDROID_CPUS:-6}"
LOG_DIR="${LOG_DIR:-$ROOT/out/logs}"
mkdir -p "$LOG_DIR"
IOS_LOG="$LOG_DIR/ios-build.log"
ANDROID_LOG="$LOG_DIR/android-build.log"
cd "$ROOT/build"

retry() { # name cmd...
  local name="$1"; shift
  for attempt in 1 2 3; do
    echo "===== $name attempt $attempt $(date) ====="
    "$@" && return 0
    [ "$attempt" = 3 ] || { echo "$name attempt $attempt failed, retrying in 5 minutes"; sleep 300; }
  done
  return 1
}

retry ios env JOBS="$IOS_JOBS" ./build.apple_stripped.sh >> "$IOS_LOG" 2>&1 &
IOS_PID=$!
echo "ios: pid $IOS_PID, log $IOS_LOG"

# The iOS script prints "=== Building" once its sync is done.
until grep -q "=== Building" "$IOS_LOG" 2>/dev/null || ! kill -0 "$IOS_PID" 2>/dev/null; do sleep 30; done

# build.android_stripped.sh retries its own sync inside the container.
./build.android_stripped.sh "$ANDROID_CPUS" >> "$ANDROID_LOG" 2>&1 &
ANDROID_PID=$!
echo "android: pid $ANDROID_PID, log $ANDROID_LOG"

wait "$IOS_PID"; IOS_RC=$?
wait "$ANDROID_PID"; ANDROID_RC=$?
echo "ios exit $IOS_RC, android exit $ANDROID_RC"
[ "$IOS_RC" = 0 ] && [ "$ANDROID_RC" = 0 ]
