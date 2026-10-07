#!/bin/bash
# Run after moving to a new upstream tag (sync.sh calls it). Answers two
# questions before anything is built:
#
#   1. Did upstream change what ITS stripped builds remove, or their base
#      settings/patches? Our targets copy those, so any difference here must be
#      mirrored into ours (or consciously rejected) — see SPEAKX.md.
#   2. Which GN build args did the new WebRTC commit add or drop? A new codec
#      or optional feature shows up here first and is a candidate to strip.
#
#   speakx/check_drift.sh [old_webrtc_commit]
#
# Exits 1 when (1) finds a difference. (2) is informational.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"
source "$B/VERSION"
OLD_COMMIT="${1:-}"
DRIFT=0
norm() { sed -E 's/ *= */=/g' | tr -s ' \t\n' '\n' | sed '/^$/d' | sort; }
section() { echo; echo "== $1"; }

section "Android: stripped GN args (ours vs upstream android_prefixed_stripped)"
python3 - "$B" <<'EOF' || DRIFT=1
import sys
sys.path.insert(0, sys.argv[1])
import run
up = set(run.TARGET_EXTRA_GN_ARGS.get('android_prefixed_stripped', '').split())
ours = set(run.TARGET_EXTRA_GN_ARGS.get('android_stripped', '').split())
print('  upstream:', ' '.join(sorted(up)))
print('  ours:    ', ' '.join(sorted(ours)))
up_p = [p for p in run.PATCHES.get('android_prefixed_stripped', []) if p != 'jni_prefix.patch']
ours_p = run.PATCHES.get('android_stripped', [])
print('  patches upstream (minus jni_prefix):', up_p)
print('  patches ours:                       ', ours_p)
bad = up != ours or sorted(up_p) != sorted(ours_p)
for t in run.WEBRTC_BUILD_TARGETS.get('android_prefixed_stripped', []):
    if t not in run.WEBRTC_BUILD_TARGETS.get('android_stripped', []):
        print('  build target missing from ours:', t); bad = True
print('  DRIFT' if bad else '  in sync')
sys.exit(1 if bad else 0)
EOF

section "iOS: stripped GN args (ours vs upstream apple_prefixed_stripped)"
extract_stripped() { awk '/^STRIPPED_GN_ARGS="/{f=1;sub(/^STRIPPED_GN_ARGS="/,"")} f{print} f&&/"$/{exit}' "$1" | tr -d '"'; }
diff <(extract_stripped "$B/build.apple_prefixed_stripped.sh" | norm) <(extract_stripped "$B/build.apple_stripped.sh" | norm) \
  && echo "  in sync" || { echo "  DRIFT (< upstream, > ours)"; DRIFT=1; }

section "iOS: base args (apple/xcframework.sh vs our apple/xcframework_ios.sh)"
extract_common() { awk '/^COMMON_ARGS="/{f=1;next} f{line=$0; sub(/"$/,"",line); print line} f&&/"$/{exit}' "$1"; }
diff <(extract_common "$B/apple/xcframework.sh" | norm | grep -vE '^(enable_dsyms|is_debug)=') \
     <(extract_common "$B/apple/xcframework_ios.sh" | norm | grep -vE '^(enable_dsyms|is_debug)=') \
  && echo "  in sync" || { echo "  DRIFT (< upstream, > ours)"; DRIFT=1; }
diff <(grep -E '^ *"iOS-' "$B/apple/xcframework.sh") <(grep -E '^ *"iOS-' "$B/apple/xcframework_ios.sh") \
  && echo "  iOS platform lines in sync" || { echo "  iOS platform lines DRIFT (deployment target?)"; DRIFT=1; }

section "iOS: patches (upstream apple_prefixed minus apple_prefix vs apple)"
python3 - "$B" <<'EOF' || DRIFT=1
import sys
sys.path.insert(0, sys.argv[1])
import run
up = [p for p in run.PATCHES.get('apple_prefixed', []) if p != 'apple_prefix.patch']
ours = run.PATCHES.get('apple', [])
print('  upstream:', up, ' ours:', ours)
sys.exit(0 if sorted(up) == sorted(ours) else 1)
EOF

section "WebRTC GN args added/removed ${OLD_COMMIT:+($OLD_COMMIT -> $WEBRTC_COMMIT)}"
if [[ -z "$OLD_COMMIT" ]]; then
  echo "  (pass the previous WEBRTC_COMMIT to list new build args)"
else
  args_at() {
    # Only names declared inside declare_args() blocks are build args.
    curl -sf "https://raw.githubusercontent.com/webrtc-sdk/webrtc/$1/webrtc.gni" | awk '
      /^declare_args\(\) *\{/ { f = 1; d = 0 }
      f { d += gsub(/\{/, "{"); d -= gsub(/\}/, "}")
          if (match($0, /^ *[a-z][a-z_0-9]* *=/)) { n = substr($0, RSTART, RLENGTH); gsub(/[ =]/, "", n); print n }
          if (d <= 0) f = 0 }' | sort -u
  }
  old_args="$(args_at "$OLD_COMMIT")"; new_args="$(args_at "$WEBRTC_COMMIT")"
  if [[ -z "$old_args" || -z "$new_args" ]]; then
    echo "  could not fetch webrtc.gni for one of the commits"
  else
    added="$(comm -13 <(echo "$old_args") <(echo "$new_args"))"
    gone="$(comm -23 <(echo "$old_args") <(echo "$new_args"))"
    echo "  added:   ${added:-none}" | tr '\n' ' '; echo
    echo "  removed: ${gone:-none}" | tr '\n' ' '; echo
    hot="$(grep -iE 'codec|h26|av1|vp[89]|dav1d|aom|video|screen|capture' <<<"$added" || true)"
    [[ -n "$hot" ]] && echo "  REVIEW (look like optional media features, strip candidates): $(tr '\n' ' ' <<<"$hot")"
    for a in $gone; do
      grep -q "$a" "$B/build.apple_stripped.sh" "$B/apple/xcframework_ios.sh" "$B/run.py" 2>/dev/null \
        && echo "  WARNING: we still set removed arg '$a'"
    done
  fi
fi

echo
[[ $DRIFT -eq 0 ]] && echo "No drift from upstream's stripped targets." || echo "Drift found: mirror upstream's change into our targets (see SPEAKX.md, 'Resolving drift')."
exit $DRIFT
