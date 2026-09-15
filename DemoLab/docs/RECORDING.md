# Record and review the product workflows

Read [SCENARIOS.md](SCENARIOS.md) before preparing a take. The five films show
travel planning and a departure notice, a camera manual, changing video subtitles,
mixed horizontal/vertical Japanese magazine text, and game dialogue in a separate
window. Zoom and Fit belong to interaction QA, not these stories.

## Own one guest

Use the exact VM name `swiftycrow-demo`. A running `tatami-demo` belongs to
another task. Never target the first running guest, stop every Tart process,
or prune unrelated VM storage. Set `TART_NO_AUTO_PRUNE=1` when cloning. The demo
guest uses 12 CPUs, 10240 MB memory and a 1920 × 1200 display with display refitting
disabled. Disable host/guest clipboard sharing for the clipboard scenarios:
the copy and paste must stay between the actual guest applications.

Share host `DerivedData/QA/tart-share` as guest
`/Volumes/My Shared Files/swiftycrow`. Copy app bundles in a ZIP archive, verify
its SHA-256 after copying, and unpack on guest-local storage. Direct virtiofs
bundle copies can fail on framework symlinks. Build the tools on guest-local
storage as well:

```sh
swift build -c release --package-path Recorder
```

Package `DemoRecorder` in an `.app` bundle with a stable bundle identifier and
`NSScreenCaptureUsageDescription`, then grant Screen Recording normally in
System Settings. Grant the input helper Accessibility permission through the
same normal UI. Grant SwiftyCrow Screen Recording permission separately. Do
not write or reset the TCC database. Changing executable paths or signatures
may require another grant.

## Prepare the real app and source

1. Build SwiftyCrow with the repository's Tuist manifest and localization gates.
   Keep the Debug bundle identifier separate from an installed release.
2. Record the app archive hash, source revision and dirty-state boundary. A
   marketing version alone does not identify a development capture.
3. Install English (US), Japanese and Korean translation models through System Settings.
4. Copy the complete `Fixtures` directory, including its manifest and original
   PNGs and MP4. Build `DemoScenes.app` with `BuildDemoScenes.swift`. Verify every
   file hash before preparing the scene. The magazine source is Japanese; all
   other sources are English. No pretranslated text is inserted into the app.
5. Set the per-locale Application Language override. Keep the translation pair
   Japanese → Korean for `layout` and English → Korean for the other four films,
   across `en`, `ko`, `ja`, `zh-Hans` and `zh-Hant` UI recordings.
   Read accessibility labels from the exact recorded app string catalog.
6. Save the guest config before changing it. Use a new output directory for every
   take and restore temporary error-path language pairs after their checks.

Use Preview for the raster documents, DemoScenes for the source video, departure
board and game, and TextEdit for the travel note and recognized Japanese article.
Prepare readable source sizes before recording; the export preserves the whole
desktop. TextEdit may start with the English note heading, but its Korean content
must come from SwiftyCrow's actual Copy Translation command and native paste.
Copy Image must similarly reach Preview through New from Clipboard.

For the game film, open the real separate translation window during preparation,
place it beside the game, then return to in-place mode and hide translation.
The filmed switch must use the app's remembered position on its first visible
frame. For the clipboard image, move Preview by a visible native titlebar drag.
Do not teleport a newly opened document with an accessibility geometry write.
Record that opening interval and leave the chapter badge absent while the new
window passes through it; retain the camera frames and actual shortcut badge.

Close Settings and obsolete source/note windows through their real controls.
Hiding SwiftyCrow is insufficient: a capture can activate it and restore other
windows. Assert that the window with accessibility identifier `settings` is
absent before selection and after the translated preview appears. An unavailable
AX tree must not count as proof of absence.

## Preview each story before recording

Substitute the actual installed paths. `--source` points to the fixture manifest,
not an HTML page. The runner verifies its asset hashes before operating the UI.

```sh
Recorder/.build/release/demoqa story \
  --film tour \
  --app /Users/admin/SwiftyCrowQA/SwiftyCrow-QA.app \
  --archive /Users/admin/SwiftyCrowQA/app-snapshot.zip \
  --locale ko \
  --catalog /Users/admin/SwiftyCrowQA/Localizable.xcstrings \
  --source /Users/admin/SwiftyCrowQA/Fixtures/manifest.json \
  --scenarios /Users/admin/SwiftyCrowQA/Fixtures/scenarios.json \
  --source-app /Users/admin/SwiftyCrowQA/DemoScenes.app \
  --config /Users/admin/.config/SwiftyCrow/config.toml \
  --mode preview \
  --output /Users/admin/SwiftyCrowQA/raw/new-session/ko/tour-preview
```

Review source-ready, translated, pasted, changed-source and separate-window stills as
applicable. Reject unreadable composition, unrelated setup windows, clipped
text and visible restoration artifacts before recording any locale
batch. `scene.json` retains the actual source window and selection geometry.

Run the same command into a fresh directory with `--mode record`,
`--recorder /path/to/DemoRecorder.app/Contents/MacOS/DemoRecorder`, `--fps 30`,
`--codec hevc`, and `--bitrate-mbps 8`. Record each of `tour`, `capture`, `live`,
`layout` and `compare` independently in every UI locale: 25 camera originals.
Do not reuse one film under several feature names or languages.

The runner uses real selection, keys, clicks and wheel events. It waits for actual
translated text, compares pasted text with the clipboard, and verifies changed
source captions or dialogue after native playback and Continue actions. Prewarming occurs
before recording; translation waits within the story remain in the camera
original. Evidence includes the action timeline and verification results.

The guest recorder writes originals to guest-local storage. The host recorder
described below writes them on the host and copies a finalized file into the
guest evidence directory. Copy completed evidence folders to the host share
after recording stops. Additional PNG capture sessions run only before or after
recording, never alongside ScreenCaptureKit.

## Recorder and environment constraints

The recorder copies captured surfaces asynchronously with Metal into a bounded
pool. It retains source buffers and Core Video texture wrappers through GPU
completion, and submits completed copies to the encoder in timestamp order.
Encoder backpressure is queued within a fixed memory bound; GPU errors, overflow,
or failure to drain at shutdown fail the take. There is no CPU-copy fallback,
synthetic replacement frame, or automatic codec downgrade. Regression tests
cover cadence accounting, queue ordering and limits, drain behavior, and actual
Metal pixel copying and resource lifetime.

Earlier large-scene takes exceeded the unchanged 1% dropped-slot limit;
missed producer slots clustered around result appearance while encoder
rejections stayed at zero. An 8-CPU guest passed the capture and comic scenes,
but repeatedly missed slots while the larger two-column result appeared.
The original recorder then passed the complete layout scene after moving to
12 CPUs and 10 GiB, rebooting, and preparing the models before recording.
CPU, RAM, reboot and cache state changed together: this establishes a working
recording configuration, not a single isolated cause or product requirement.
The later, larger magazine scene still exceeded the limit after the same setup
and another reboot. Independent guest timers paused together while an aligned
host timer kept running. This narrows the scheduling boundary but does not prove
a particular GPU or virtualization defect. Keep rejected takes and their timing
evidence; do not relax the cadence gate.

### Host capture of the owned VM

`HostRecorder` captures only the owned VM window, restricted to its complete
1920 × 1200 guest viewport. On a 2× host display, the viewport must be exactly
960 × 600 points. Window ownership, title, display, backing scale and geometry
are checked; output resizing is disabled. Verify the raw viewport against an
independent guest screenshot before a batch. The capture includes the real host
cursor, so mouse input must reach the guest through that same native VM view.
A guest cursor warp alone does not establish that the host pointer follows it.

Keep the owned VM outside automatic window tiling during the batch. In the
September 11 run, Tatami retiled the Tart window after region selection and
the input geometry check correctly stopped the take before recording. A
temporary `unmanaged` membership for Tart in its current workspace prevents
that resize without tiling or mirroring the window. Record the exact added
entry, verify the live membership, and remove only that entry after closing
the owned VM; preserve unrelated configuration edits. Restore and verify the
original viewport before resuming. Do not disable the geometry check.

The September 11 host-view experiment used an isolated Tart 2.36.0 checkout
at `16d186c253a449ccbac640c38b3c00c91c9a68b9`. Only the SwiftUI minimum window
width and height in `Run.swift` changed, from the guest display dimensions to
320 and 200 points; ideal dimensions and guest display configuration stayed
unchanged. It was built with Xcode 27 RC and `swift build -c release
--build-system swiftbuild`, packaged with the upstream app resources and signed
with its development entitlements. The global Tart installation was unchanged.
Earlier local builds entered a run loop without opening a window or starting
the guest; the Xcode 27 build opened the window successfully. Preserve the exact
build and runtime evidence rather than attributing the difference to a proven
compiler defect. Set `tart set swiftycrow-demo --no-display-refit`, then run the owned
guest with `--no-clipboard --no-audio`, and verify the guest display remains 1920 × 1200 at 1× after resizing.

Supply a JSON viewport containing `ownerPID`, `windowID`, `displayID`, `title`,
`x`, `y`, `width`, `height` and `scale`. Coordinates are relative to the selected
host display. Start `HostRecorder viewport.json /host/shared/control-directory`
under a launcher with Screen Recording permission. Start the input service
under a launcher with Accessibility permission:

```sh
HostMouseRelay viewport.json HOST_IPV4 GUEST_IPV4 private-input-config.json input-traces
```

Substitute the current IPv4 addresses of the owned host VM interface and guest.
The service binds that interface, restricts peers to the guest, and writes an
ephemeral port and authentication token into a mode-0600 configuration. Copy
that file to guest-local private storage; keep it out of published evidence.
The sanitized input trace retains the server hash, session ID, viewport and
actual event times without the token or port.

Set `SWIFTYCROW_HOST_MOUSE_CONFIG` to that guest-local configuration and
`SWIFTYCROW_HOST_CAPTURE_ROOT` to the control directory's guest mount path on
the `demoqa story` process. The child recorder inherits both variables. Give
`--recorder` the `RecorderRelay` executable and use the same 30 fps, HEVC and
8 Mbps arguments as above. Use a new control directory for a camera session.

The relay exchanges camera start/stop requests through atomic files in the
owned share. Clock requests use the same authenticated, guest-scoped TCP
connection as native host mouse input, configured by
`SWIFTYCROW_HOST_MOUSE_CONFIG`. Shared-folder round trips were too slow for
clock alignment and are not used for that measurement. The relay measures
nine clock round trips before recording and nine after completion,
retains all samples, and uses the shortest round trip to map the first host
frame into the guest input timeline. The selected round trips must each be
under 20 ms; measured offset change plus both uncertainty bounds must remain
below one 30 fps frame. Clock domains are never assumed to share an epoch.
The guest runner's SIGINT finalizes the host movie before evidence is copied.
The host original, raw first-frame clock, mapped clock and recorder executable
hash remain available for audit. A take that fails alignment or geometry checks
cannot be exported as successful.

Guest HTTPS previously timed out with `en0` MTU 1500 while the host succeeded.
A guest-only A/B/A/B comparison (1500 → 1280 → 1500 → 1280), including TLS 1.2
and HTTP/1.1 checks, isolated the session constraint. Runtime MTU 1280 allowed
model downloads and real translation. No host VPN or persistent network
configuration was changed. Do not apply this as unconditional machine setup.

## Visual acceptance and export

Full decoding, low drop counts, OCR, AX assertions and healthy logs are separate
checks. None proves the rendered image is clean. Review the entire original and
consecutive frames through selection, translation appearance, copy/paste, source
changes, mode changes and dismissal wherever the story includes them.

Reject black remnants, magenta surfaces, missing content, source restoration
artifacts and other graphics corruption, even if transient. Compare suspected
original frames with independent guest PNGs and retain their timestamps and
WindowServer/Metal logs. Do not crop corruption out, disable product effects,
or replace real translation with fixture state to pass. Repeat a take when
its dropped-frame rate exceeds 1%.

Export the accepted, full-length original to H.264/yuv420p MP4 with `+faststart`.
Burn in the localized chapter, stage captions and actual shortcut badges using
`presentation.json` and `Localization/Narration.json`. The first-frame epoch must
match `capture-demo.ready.json`; cue times come from the native input runner, and
the final duration comes from recorder statistics. Allow the core shortcuts time
to be read before the next action. Internal caret positioning remains in the
input evidence but is omitted from the displayed shortcut badges. Preserve dimensions, every
frame and the full timeline. Keep sources and product windows clear of the
actual top badge bounds and above the bottom caption band. Choose a poster that shows the
feature's meaningful result. Decode the export completely and compare its
transition frames with the original. Retain both hashes and the unmodified MOV,
recorder JSON, timeline, independent screenshots, AX snapshots and logs.

Audit each original and record its visual verdict before exporting. Substitute
the actual reviewed timestamp for `12`. Use an FFmpeg build with libass; set
`SWIFTYCROW_FFMPEG` when it is installed separately from the default executable
(for example `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`):

```sh
swift run --package-path Tools swiftycrow-tools audit-video \
  --source DerivedData/QA/new-session/ko/tour/capture-demo.mov \
  --output DerivedData/QA/new-session/ko/tour/rendering-audit

swift run --package-path Tools swiftycrow-tools export-video \
  --source DerivedData/QA/new-session/ko/tour/capture-demo.mov \
  --film tour --locale ko --poster-seconds 12 \
  --review-report DerivedData/QA/new-session/RENDERING-REVIEW.md
```

After all 25 independent exports pass visual comparison:

```sh
swift run --package-path Tools swiftycrow-tools media-manifest \
  --recorded-catalog DerivedData/QA/new-session/Localizable.xcstrings \
  --review-report DerivedData/QA/new-session/RENDERING-REVIEW.md
swift run --package-path Tools swiftycrow-tools site --output DerivedData/LocalizedSite
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/LocalizedSite --port 8765
```

Preserve the recorded app catalog alongside the evidence. Its raw hash must
match every scene. Comparison with the current catalog ignores only translator
comments, while requiring every other field to match and retaining both hashes.
The manifest rejects missing films, locale/film/language-pair mismatches, stale
fixture assets, scenarios or catalogs, mixed app archives, inconsistent reviews,
and changed media, subtitle or presentation files.

Check every feature film, poster, language selection and README section link in
the generated site at desktop and mobile widths. Review remaining locale copy
with native readers before release. VM evidence establishes these recorded
interactions, not physical trackpad feel or behavior on every display and OS.

## Separate interaction regression checks

The `demoqa collect` and legacy `demoqa capture` commands still use
`source-sample.html` to exercise Settings, error paths, Zoom and Fit. They are
regression evidence, not substitutes for the product films. Keep their output
in a separate directory and do not export them under the five story IDs.

### Korean 2.10.0 review session

The September 15 Korean batch uses guest-local `DemoRecorder` successfully at
1920 × 1200 and 30 fps. All five scenarios pass; four takes have no missed slots,
and the mixed-direction layout take has 2 of 664 slots missed (0.301%). This is
fresh evidence for this VM session, not a claim that the September 11 scheduling
regression is fixed. Preserve the per-take statistics and continue enforcing the
1% gate. Host camera/input relays are not used for these final takes.

Disable Tips notifications through guest System Settings before framing the
source. The system hides notifications when capture begins, so an existing banner
can remain in the first frames even though later frames look clean. Check frame
zero, park the pointer away from controls to avoid tooltips, and let preparation
windows settle before starting the recorder. Never edit an alert out of footage.

### Translation output must match the page

New recordings use `DemoLab/Scenarios/localized-2.10.json`. The runner requires the
translation target language and script to match `--locale` and checks complete
localized picker values. It also verifies real translated text fragments; full AX
values are read for assertions, so long paragraphs are not silently truncated.
`FilmLanguagePair` enforces the same contract in exports and site assembly.

Changing only UI language and editorial subtitles does not produce a localized
demo. Select foreign source material suitable for the target page and confirm the
actual output in capture results and live windows. Original-text copying in the
layout demo intentionally remains in the source language and is labeled as such.
