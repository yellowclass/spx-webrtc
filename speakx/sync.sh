#!/bin/bash
# Moves our stripped targets onto a new upstream release tag.
#
#   speakx/sync.sh 150.7871.03
#
# Our work is the commits in m<old>..main. They are replayed onto m<new> with
# a rebase, so main always equals "upstream tag + our commits" and the WebRTC
# source commit comes from upstream's build/VERSION, never from us.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NEW="${1:?usage: speakx/sync.sh <version, e.g. 150.7871.03>}"

[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean; commit or discard first."; exit 1; }
[[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || { echo "Run from main."; exit 1; }

source build/VERSION
OLD="$WEBRTC_VERSION"
OLD_COMMIT="$WEBRTC_COMMIT"
[[ "$OLD" != "$NEW" ]] || { echo "Already on $NEW."; exit 0; }

git fetch upstream --tags --force --quiet
git rev-parse -q --verify "refs/tags/m$NEW" >/dev/null || { echo "Upstream has no tag m$NEW yet. Tags: $(git tag -l 'm*' | tail -5 | tr '\n' ' ')"; exit 1; }

echo "Replaying our commits ($(git rev-list --count "m$OLD"..main)) from m$OLD onto m$NEW"
git tag -f "speakx-before-$NEW" main >/dev/null
if ! git rebase --onto "m$NEW" "m$OLD" main; then
  echo
  echo "Rebase stopped on a conflict. Resolve it as described in SPEAKX.md ('Resolving rebase conflicts'),"
  echo "then: git rebase --continue && speakx/check_drift.sh $OLD_COMMIT"
  echo "To abandon: git rebase --abort (main is untouched; backup tag speakx-before-$NEW)."
  exit 1
fi

source build/VERSION
echo "Now on $WEBRTC_VERSION (webrtc $WEBRTC_COMMIT)"
speakx/check_drift.sh "$OLD_COMMIT" || true

cat <<EOF

Next:
  1. Fix any drift reported above (SPEAKX.md, 'Resolving drift').
  2. Build:   ./build/build.android_stripped.sh 6
              JOBS=3 ./build/build.apple_stripped.sh
  3. Verify:  speakx/check_api.sh
  4. Package: speakx/package.sh <ios_zip_url>
  5. Publish and bump the app (SPEAKX.md, 'Release checklist').
  6. git push origin main && git tag speakx-$WEBRTC_VERSION && git push origin speakx-$WEBRTC_VERSION
EOF
