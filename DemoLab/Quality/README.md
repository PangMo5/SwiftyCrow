# Capture quality checks

The independent WebKit fixture covers a file toolbar, navigation, two tables,
inline code, italic wrapped prose, Arabic paragraphs and Japanese vertical text.
Generate both widths and both themes into a fresh directory:

```sh
swiftc -parse-as-library -target arm64-apple-macos26.0 \
  DemoLab/Quality/GenerateWebFixtures.swift -o /absolute/GenerateWebFixtures
/absolute/GenerateWebFixtures \
  "$PWD/DemoLab/Quality/Fixtures/reading-workspace.html" /absolute/new-corpus
```

Run the generator in the same macOS environment as the probe when comparing
results. It waits for fonts and browser layout, rejects clipped pages, and writes
12 authored cases: Korean, Arabic and German targets for four source layouts.
SVG protection rectangles come from the independent DOM, never from recognition.
No SwiftyCrow module or generated translation is used to author expectations.

Build the current app with XcodeBuildMCP before packaging a probe:

```sh
xcodebuildmcp macos build --workspace-path "$PWD/SwiftyCrow.xcworkspace" \
  --scheme SwiftyCrow --configuration Debug --derived-data-path "$PWD/DerivedData"
bash DemoLab/Quality/BuildProbe.sh capture /absolute/new/CaptureProbe.app
bash DemoLab/Quality/BuildProbe.sh tests /absolute/new/Tests.app
bash DemoLab/Quality/BuildNativeApp.sh /absolute/new/NativeQA.app
```

Use a fresh output path for each build and run. The probe packages the actual
app module, its runtime dependencies and matching Swift Testing runtime. Selected
test files can follow the test command's output argument. Include their shared
support files. Source snapshots prevent edits during compilation from changing
the test inputs. Compare the module and executable SHA-256 hashes on both sides
of the Tart share before running.

Run in `swiftycrow-demo`, with guest paths adjusted to the configured share:

```sh
tart exec swiftycrow-demo \
  /guest/CaptureProbe.app/Contents/MacOS/CaptureProbe \
  /guest/corpus-root /guest/new-results
tart exec swiftycrow-demo env SWIFTYCROW_TEST_TEMP_ROOT=/guest/writable-temp \
  /guest/Tests.app/Contents/MacOS/swiftpm-testing-helper \
  /guest/new-tests.xml
```

`corpus.json` uses `CaptureQualityCase` from `Tests/CaptureQualitySelection.swift`.
Existing `SWIFTYCROW_QUALITY_*` selectors apply to the probe. It replaces screen
acquisition with the original image while invoking the real capture reducer,
Vision recognition, installed Apple translation models, source restoration and
export renderer. Enable `SWIFTYCROW_QUALITY_TRACE=1` to retain intermediate OCR,
restoration-only and target-only images. Exact occurrence counts and forbidden
transcripts complement presence checks; repeated glyphs must neither disappear
nor be counted twice. Failures remain failures rather than relaxed thresholds.

Every report also checks retained source pixels, including pending and literal
owners. Correct OCR classification alone cannot establish that the exported
image preserved those pixels. `retainedSourcePixelChanges` is separate from the
authored graphic regions and transcript gates. The source protection mask is a
pixel-aligned vector difference, with winding fill for overlapping owners.
Capture preview/export and the transparent live layer share
`OverlayRasterRenderer`: Core Graphics draws the source, then clips restoration
and target ink to that difference. Horizontal Core Text draws directly into the
final pixel grid, avoiding resampling a ceil-sized intermediate bitmap; vertical
text uses its glyph image. Background colors explicitly use sRGB. This avoids a separate SwiftUI offscreen-compositing contract in Save/Copy.

Keep authored fixtures and their expectations independent of generated outputs.
Inspect the original, baseline and candidate at source resolution, especially
changed regions and graphic boundaries. Automated gates do not establish fluent
translation or complete artwork preservation. Fixture replay also does not test
screen acquisition, selectors, hotkeys, native Save/Copy or Live interaction.

The authored toolbar requires centered Print/Share labels, and the reference
table requires its original leading column anchors. Thin outlined controls need
an enclosed component at glyph resolution: a component touching the bounded
search edge is open whitespace, not a control. Unequal-width source labels in
one native table column establish leading, centered or trailing alignment;
estimated cell padding must not move that observed anchor. Unit tests cover
open/closed outlines, light/dark backgrounds and column alignment at two scales.
When Vision includes an empty radio or checkbox in a label box but omits it from
the transcript, a separated taller closed outline remains source artwork. Both
the erasure patches and target owner are restricted to the adjacent label ink;
a letter O or an open stroke cannot establish that ownership change.

Every target must fit inside its own original text box. A paragraph owns its
paragraph box; separate menu items retain their individual boxes and positions.
Whitespace, detected control interiors and table cells cannot enlarge target
bounds. Fitting includes glyph antialias margins and final raster clipping enforces
the same invariant for preview, Save/Copy and live output. A single physical row
uses its measured source ink center without shrinking the fitting height to a
Latin cap height. The runner checks the boundary globally on every placement.

Raised references are captured as inline owners before paragraph joining.
Their immutable pixels and relative baseline follow their translated clause
through protected translation markers. Thin separators in bracketed control
rows divide independent caption owners, keeping each caption in its original
box and the separator at the original control boundary.
Chromatic ink can recover a dropped bracket outside Vision's incomplete range
box. Whole paragraphs retain their original boundary; inline elements no longer
reserve obsolete source coordinates or overlap translated text.

For those interactions, install the normal app packaged by `BuildNativeApp.sh`.
It keeps the production module's exact bytes and the build's Apple Development
signer. The fixed QA bundle identity is separate from an installed release.
Ad-hoc signing generates a changing code-hash requirement and can leave an
enabled screen-recording switch that macOS still rejects. Replace an obsolete
QA registration through normal System Settings UI when migrating that identity;
never edit TCC databases. Keep the installed app path stable afterward.

Record actual native acquisition separately from fixture replay. Use only this
task's VM. Preserve source images and reports when reclaiming storage; disposable
compiled runtimes and download caches can be regenerated. CPU/GPU-intensive
checks should run serially when collecting comparable stage timings.

For a Debug native acquisition trace, launch the installed app with
`open --env SWIFTYCROW_NATIVE_TRACE_ROOT=/guest/new-traces /guest/NativeQA.app`.
This explicit opt-in writes the selected source pixels and capture-local OCR,
geometry, detected languages and context groups into a new UUID directory.
It does not capture outside the selected region. Release builds exclude this
recorder; normal Debug launches perform no diagnostic image I/O.
Opt-in render traces retain the actual preview/export input, replacement state
and protection frames. Distinguish a modified source window from a compositing
failure before changing restoration. Activate the QA app before a configured
shortcut, verify the selector is visible, then drag: a shortcut also understood
by the source app must not edit the fixture during automation.
