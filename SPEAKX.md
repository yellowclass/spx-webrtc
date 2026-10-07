# SpeakX stripped WebRTC

This is SpeakX's fork of [webrtc-sdk/webrtc-build](https://github.com/webrtc-sdk/webrtc-build), the build repo that produces the WebRTC binaries `flutter_webrtc` and `livekit_client` use. We build the **same WebRTC source commit** as upstream, with the video codecs our audio-only calls never use removed, and ship it in place of upstream's binary on Android and iOS.

| | Upstream (what the plugins pull) | Ours |
|---|---|---|
| Android | `io.github.webrtc-sdk:android:<ver>` | `in.speakx.webrtc:android-stripped:<ver>` |
| iOS | pod `WebRTC-SDK` `<ver>` | pod `WebRTC-SDK` `<ver>`, from our podspec |
| Android arm64 `.so` (150.7871.01) | 12.29 MB / 5.91 MB download | 7.71 MB / 3.50 MB download |
| iOS arm64 binary (150.7871.01) | 12.35 MB / 5.70 MB download | 7.60 MB / 3.38 MB download |

Download figures are gzip -9 of the binary, which tracks what Play and the App Store transfer.

## What we strip, and what we keep

Removed (build args):

| Arg | Removes | Platforms |
|---|---|---|
| `enable_libaom = false` | AV1 encoder (libaom) | Android, iOS |
| `rtc_include_dav1d_in_internal_decoder_factory = false` | AV1 decoder (dav1d) | Android, iOS |
| `rtc_libvpx_build_vp9 = false` | VP9 | Android, iOS |
| `rtc_use_h265 = false` | H.265 | Android only (on Apple it is VideoToolbox-backed: no size win, and the ObjC factories need it) |
| `optimize_for_size = true` | compiles everything with `-Os` | Android, iOS |

Already off in upstream's normal build too: software H.264 (`rtc_use_h264 = false`), protobuf event log, examples, tools, tests.

Kept: Opus and every audio codec, the audio processing module (echo cancellation, noise suppression, AGC), VP8 (LiveKit's default video codec, needed for SDP negotiation), data channels (LiveKit signalling uses them), frame cryptor (E2EE), the full Java and ObjC API.

These are **exactly** the args upstream uses for its own `android_prefixed_stripped` and `apple_prefixed_stripped` targets (LiveKit's native SDKs ship those). The only thing we drop is the prefixing (`jni_prefix.patch`, `apple_prefix.patch`), which renames everything to `livekit.org.webrtc.*` / `LKRTC*`. Without it, the API stays `org.webrtc.*` / `RTC*`, so the plugins link against our build unchanged.

### Why it is a drop-in

Checked by `speakx/check_api.sh` against upstream's full build of the same version:

- Android: identical Java classes and identical JNI exports. Removed codecs keep their entry points and report "not supported" at runtime.
- iOS: the only removed symbols are `RTCVideoEncoderAV1` and `RTCVideoDecoderAV1`, and neither `flutter_webrtc` nor `livekit_client` references them.
- Our calls are audio-only: no video track, camera or renderer, so the removed video codecs are never negotiated.

## What lives where

Everything SpeakX-specific is in these files. Everything else is upstream and must not be edited here (edits would conflict on every sync).

| File | Purpose |
|---|---|
| `build/run.py` | small edits: registers the `android_stripped` target (patch list, build targets, GN args shared with `android_prefixed_stripped` through `ANDROID_STRIPPED_GN_ARGS`), and reads `GCLIENT_JOBS` for the `gclient sync --jobs` value |
| `build/build.android_stripped.sh` | local Android build in a linux/amd64 Docker container |
| `build/android_stripped/Dockerfile` | same build as a Docker image (CI parity with upstream's other Android targets) |
| `build/build.apple_stripped.sh` | iOS build; holds the iOS strip list (`STRIPPED_GN_ARGS`) |
| `build/apple/xcframework_ios.sh` | iOS-only copy of upstream `apple/xcframework.sh` (device arm64, simulator arm64 + x64) |
| `speakx/build_all.sh` | build iOS then Android without overlapping their source syncs |
| `speakx/sync.sh` | move our commits onto a new upstream release tag |
| `speakx/check_drift.sh` | compare our strip list and base args with upstream's, list new WebRTC build args |
| `speakx/check_api.sh` | prove the build is a drop-in, print the size win |
| `speakx/package.sh` | make the Maven artifact and the podspec |
| `speakx/publish.sh` | upload them as GitHub release `speakx-<ver>` |
| `speakx/downgrade_class_version.py` | vendored from webrtc-sdk/android (MIT, `speakx/LICENSE.webrtc-sdk-android`): stamps the AAR's classes from Java 21 back to Java 17, as upstream does before publishing |
| `SPEAKX.md` | this file |

Branches and tags:

- `main` = upstream release tag + our commits on top. Always.
- Upstream remote is `upstream` (webrtc-sdk/webrtc-build). Its tags look like `m150.7871.01`.
- Our release tags look like `speakx-150.7871.01`, one per published version.

## Building

Needs about 60 GB free disk and a few hours the first time (most of it is the source download); later builds reuse the synced source.

The normal way to build both:

```bash
speakx/build_all.sh          # logs in out/logs/
```

It syncs iOS first and starts Android once iOS is compiling, so the two source downloads never overlap: googlesource rate-limits one IP with HTTP 429 and two full syncs at once trip it. It also lowers gclient's parallel clones (`GCLIENT_JOBS`, default 3 here; upstream uses 8). Rerunning after a failure resumes the sync.

The per-platform scripts below are what it calls.

### Android

WebRTC only builds for Android on an x86_64 Linux host, so it runs in Docker (on Apple Silicon through Rosetta). Docker Desktop must be running.

```bash
./build/build.android_stripped.sh 6     # 6 = CPUs for the container
```

- Source and build output live in the Docker volume `speakx-webrtc-android-src`, so an interrupted or failed build resumes instead of re-syncing ~30 GB.
- Only the AAR is built (`--webrtc-nobuild` skips the four per-ABI `libwebrtc.a` builds nobody ships).
- Output: `build/_package/android_stripped/libwebrtc.aar` (4 ABIs).
- M150+ compiles the Java with a JDK 21 target. The script stamps the classes back to Java 17 at the end, exactly like upstream's published AAR; without it, apps on JDK 17 fail to compile against the AAR with `bad class file`. `check_api.sh` fails if the class version differs from upstream's.
- Log tip: `docker logs -f speakx-webrtc-android`.

### iOS

Builds natively on a Mac with Xcode.

```bash
JOBS=3 ./build/build.apple_stripped.sh
```

- Source syncs into `build/_source/apple/` (shared with upstream's `apple` target).
- Output: `build/_package/apple_stripped/WebRTC.xcframework` and `.zip`.
- If a newer Xcode turns a new warning into a build error, add `treat_warnings_as_errors = false` to `STRIPPED_GN_ARGS` in `build.apple_stripped.sh` for that build and note it in the release notes.
- **Xcode 27+**: WebRTC M150's bundled `lld` cannot read the iOS 27 SDK (`unknown architecture` / `arm64e.x1` in `.tbd` files at link time). `xcframework_ios.sh` detects SDK 27+ and links with Apple's `ld` instead (`use_lld = false`). That binary is about 0.6 MB larger than an Xcode 26 + `lld` build because Apple's `ld` folds less identical code; for exact parity with upstream, build iOS with Xcode 26 (upstream CI uses it). `check_api.sh` allows the small export differences Apple `ld` causes (compiler-rt `___emu*` helpers, extra C++ internals).

### Verify, package, publish

```bash
speakx/check_api.sh      # must print "OK: drop-in compatible"
speakx/package.sh        # -> out/release/speakx-<ver>/ (exact mirror of the GitHub release)
speakx/publish.sh        # uploads that folder as GitHub release speakx-<ver>
```

## Using it in an app

Both plugins pin one WebRTC version. We swap that dependency; no plugin or app code changes.

**Android**, `android/build.gradle`:

```groovy
allprojects {
    repositories {
        // Stripped WebRTC, served from github.com/yellowclass/spx-webrtc releases.
        ivy {
            url "https://github.com/yellowclass/spx-webrtc/releases/download"
            patternLayout {
                artifact "speakx-[revision]/[artifact]-[revision].[ext]"
                ivy "speakx-[revision]/ivy-[revision].xml"
            }
            metadataSources { ivyDescriptor() }
            content { includeGroup "in.speakx.webrtc" }
        }
    }
    configurations.all {
        resolutionStrategy.dependencySubstitution {
            substitute module("io.github.webrtc-sdk:android")
                using module("in.speakx.webrtc:android-stripped:150.7871.01")
        }
    }
}
```

**iOS**, `ios/Podfile` (inside the Runner target):

```ruby
pod 'WebRTC-SDK', :podspec => 'https://github.com/yellowclass/spx-webrtc/releases/download/speakx-150.7871.01/WebRTC-SDK.podspec.json'
```

Same pod name and version as upstream, so the plugins' `'WebRTC-SDK', '150.7871.01'` requirement is satisfied by ours. Run `pod install` and commit `Podfile.lock`.

**Testing a build before publishing**: `speakx/package.sh --local`, then build the app with `SPX_WEBRTC_REPO=file://<this repo>/out/release` (Gradle) and `SPX_WEBRTC_PODSPEC=<this repo>/out/release/speakx-<ver>/WebRTC-SDK.podspec.json pod install` (iOS), if the app's Gradle and Podfile read those variables. Don't commit the `Podfile.lock` from a local test: it records the local path.

**Rollback**: delete those lines (Gradle substitution + ivy repo, Podfile line, then `pod install`). The app goes straight back to upstream's binary of the same version.

## Syncing to a new version

Do this whenever `livekit_client` or `flutter_webrtc` is upgraded in the app. Each plugin release pins a WebRTC version, and the app must ship **our build of exactly that version**.

### 1. Find the version the new plugins pin

```bash
grep "webrtc-sdk:android" ~/.pub-cache/hosted/pub.dev/flutter_webrtc-<new>/android/build.gradle ~/.pub-cache/hosted/pub.dev/livekit_client-<new>/android/build.gradle
grep "WebRTC-SDK" ~/.pub-cache/hosted/pub.dev/flutter_webrtc-<new>/ios/flutter_webrtc.podspec ~/.pub-cache/hosted/pub.dev/livekit_client-<new>/ios/livekit_client.podspec
```

All four must agree. If they don't, the plugins disagree among themselves; fix that in the app first.

### 2. Move our commits onto upstream's tag

```bash
speakx/sync.sh 150.7871.03
```

It checks the tree is clean, fetches upstream tags, tags the current `main` as `speakx-before-<ver>` (backup), and rebases our commits from `m<old>` onto `m<new>`. `build/VERSION` (and so the WebRTC source commit) comes from upstream's tag. Never edit it by hand.

If upstream has not tagged that version yet, wait for it, or build from their branch only for testing (never ship an untagged build).

### 3. Resolving rebase conflicts

Almost always in `build/run.py`, because upstream edits the same lists we extend. The rule: **take upstream's version, then re-add `android_stripped` next to `android_prefixed_stripped`**. Concretely, after resolving, `android_stripped` must appear in:

- every `target in [...]` list that contains `android_prefixed_stripped`;
- `PATCHES`: same list as `android_prefixed_stripped` minus `jni_prefix.patch`;
- `WEBRTC_BUILD_TARGETS`: same list as `android_prefixed_stripped`;
- `TARGET_EXTRA_GN_ARGS`: both keys pointing at `ANDROID_STRIPPED_GN_ARGS` (if upstream changed their string, put their new string in the constant);
- `TARGETS`;

and the `gclient sync` call must still read `--jobs` from `GCLIENT_JOBS`.

```bash
grep -n "android_prefixed_stripped" build/run.py    # every hit should have an android_stripped twin
git add build/run.py && git rebase --continue
```

If `apple/xcframework.sh` changed upstream, our copy `apple/xcframework_ios.sh` does not conflict (it is a separate file); `check_drift.sh` catches it in the next step.

To give up: `git rebase --abort`. `main` is unchanged.

### 4. Check drift: what to strip in the new release

`sync.sh` runs this automatically; you can rerun it any time:

```bash
speakx/check_drift.sh <old WEBRTC_COMMIT>     # sync.sh passes it for you
```

It reports:

1. **Our strip list vs upstream's** (Android GN args and patches, iOS `STRIPPED_GN_ARGS`).
2. **Our iOS base args vs upstream's `apple/xcframework.sh`** (`COMMON_ARGS` and the iOS platform lines, which include the deployment target).
3. **WebRTC build args added or removed** between the old and new WebRTC commit (from `webrtc.gni` `declare_args()` blocks). Args that look like optional media features are listed under REVIEW.

#### Resolving drift

- **Upstream added something to their stripped list**: add the same arg to ours (`ANDROID_STRIPPED_GN_ARGS` in `run.py` and/or `STRIPPED_GN_ARGS` in `build.apple_stripped.sh`). They ship it in LiveKit's own SDKs, so it is safe by construction. Then confirm with `check_api.sh` that the API still matches.
- **Upstream removed something from their list**: remove it from ours too. It usually means the arg broke something.
- **Upstream changed `COMMON_ARGS` or the iOS platform lines**: copy the change into `apple/xcframework_ios.sh`. Keep our two intentional differences: no non-iOS platforms, `JOBS` instead of `PARALLEL_BUILDS`.
- **A new WebRTC arg is listed under REVIEW**: decide whether to strip it. Strip only if all of these hold:
  1. it is a video, screen-share or other non-audio feature;
  2. `grep -rn` of the feature's class names in `~/.pub-cache/hosted/pub.dev/flutter_webrtc-<ver>` and `livekit_client-<ver>` (android, ios, common, shared_swift) finds nothing;
  3. after building with it off, `check_api.sh` passes (or the only removed symbols are ones you add to `IOS_ALLOWED_REMOVALS` in `check_api.sh` after confirming step 2 for them);
  4. a call still works on both platforms.

  Anything touching audio, data channels, ICE/networking or encryption: never strip.
- **We still set an arg WebRTC removed** (WARNING line): delete it from our scripts, or GN errors out.

Commit drift fixes on `main` as separate commits with a message saying what changed upstream.

### 5. Build, verify, publish

```bash
./build/build.android_stripped.sh 6
JOBS=3 ./build/build.apple_stripped.sh
speakx/check_api.sh
speakx/package.sh
speakx/publish.sh
git push origin main
git tag speakx-<ver> && git push origin speakx-<ver>
```

### 6. Bump the app

In the same app change as the plugin upgrade:

- `android/build.gradle`: change the version in `using module("in.speakx.webrtc:android-stripped:<ver>")`.
- `ios/Podfile`: change both `<ver>`s in the podspec URL, run `pod install`.

## Release checklist

- [ ] `speakx/sync.sh <ver>` done, conflicts resolved per section 3
- [ ] `speakx/check_drift.sh` clean, or every drift resolved and committed
- [ ] Both builds green
- [ ] `speakx/check_api.sh` prints `OK: drop-in compatible`; size win roughly matches the table at the top
- [ ] Sizes match upstream's own stripped build of the same version within ~1% (`io.github.webrtc-sdk:android-prefixed-stripped:<ver>` on Maven Central, `LiveKitWebRTC-stripped.xcframework.zip` on upstream's release); a big gap means an arg did not apply
- [ ] `speakx/package.sh` + `speakx/publish.sh`; release `speakx-<ver>` has 5 assets (aar, pom, ivy xml, xcframework zip, podspec)
- [ ] App bumped (Gradle + Podfile); a release build installs and starts
- [ ] Smoke test on a low-end Android phone and an iPhone: a LiveKit voice call of every kind the app makes, each at least 2 minutes; audio both ways, no echo; watch CPU in Android Studio / Instruments against the previous build (the `-Os` build must not make audio processing stutter)
- [ ] Any call path that starts WebRTC outside the main Flutter engine (for example a native incoming-call screen) still connects
- [ ] `main` and `speakx-<ver>` tag pushed

## Troubleshooting

- **Docker build very slow or `exec format error`**: Docker Desktop → Settings → General → enable "Use Rosetta for x86_64/amd64 emulation on Apple Silicon".
- **`No space left on device` in Docker**: raise the Docker Desktop disk limit, or `docker builder prune` (the source volume is separate and survives this).
- **Start the Android build from scratch**: `docker volume rm speakx-webrtc-android-src`.
- **`gclient sync` fails with HTTP 429** (googlesource rate limit): don't run the Android and iOS syncs at the same time. The Android script retries 3 times; for iOS, rerun the script (`--webrtc-fetch` resumes the sync).
- **`check_api.sh` cannot download upstream artifacts**: upstream publishes the Maven artifact and the `WebRTC-SDK` pod a little after tagging; wait and retry.
