# SwiftyCrow tools

Swift automation for app localization, generated user documentation, website
assembly, localized Sparkle notes, local previews, and reviewed video exports.
The structure follows Tatami's `Tools` package; dependencies stay outside the
product app and the offline `DemoLab/Recorder` package.

Run from the repository root with Swift 6.2 or later:

```sh
swift run --package-path Tools swiftycrow-tools check
swift test --package-path Tools
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools site --output DerivedData/Site
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/Site --port 8085
```

`collect-docs` and `collect-web` collect English source units without inventing
translations. `sync-app --stringsdata <directory>` reconciles compiler output;
`check-app --stringsdata <directory>` rejects missing or stale runtime keys.
Run `docs` after reviewing catalog changes. `docs --check` validates generated
files without writing them.

The preview server binds only to loopback and serves files from the selected
output directory. It supports the byte ranges used by video players. Stop the
foreground process with Control-C.

`appcast-notes --output <appcast.xml> --version <version>` embeds release notes
for all five locales, collecting patches back to the start of that minor series.
It preserves enclosure attributes and fails if the requested notes are absent.

`export-video --source <original.mov> --film <id> --locale <locale> --poster-seconds <time>
--review-report <report>` exports an already reviewed camera original. It verifies
recorder status and drops, preserves the full frame and timeline, completely
decodes the H.264 output, and writes hashes and recording metrics beside it.
Visual review remains a separate requirement.

Exports burn in localized chapters, captions and actual shortcut badges from the
recording's `presentation.json`. FFmpeg must include the `ass` filter, and
Fontconfig must resolve the specified macOS fonts. If the default `ffmpeg` lacks
libass, set `SWIFTYCROW_FFMPEG` to a build that includes it, for example
`/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`. The exporter fails explicitly when
the filter or a required font is unavailable.

Use `select-takes`, `export-batch`, and `merge-review-bundle` to assemble current
review media. The selection pins each camera original and its independent
runtime, language, narration, and review evidence. `verify-media` checks the
complete bundle; `install-assets` copies it into a fresh verified directory.
The former single-archive `media-manifest` command has been replaced by this
workflow. Historical publication manifests remain as evidence, not as input to
the current assembler. See the maintained workflow below for complete commands.

The initial migration preserved the existing translated documents byte for byte.
Swift Testing covers translation contracts, generated output, release metadata
and media ranges. On macOS, JavaScriptCore also exercises the website's actual
`docs.js` grouping and failure behavior without a separate Node test runner.

`audit-video --source <movie> --output <review-directory>` uses AVFoundation on
macOS to inspect every decoded frame and produce full-frame contact sheets. It
records pixel hashes, exact duplicates, timestamps and dark/magenta counts, and
preserves full-resolution frames with the largest counts. Inspect the images;
the command deliberately leaves visual acceptance pending. Row padding is removed
before hashing so decoder allocation details cannot masquerade as visual changes.

## Review one language before producing the others

`docs --locale ko` and `check --locale ko` generate/check only Korean document
outputs and text catalogs while preserving the other generated documents.
App strings are checked in English and the selected locale; film and narration
catalog checks still run across all languages. `site --locale ko --media-root <directory> --output <preview>`
builds only Korean pages and selects `<directory>/ko/{film}.{mp4,jpg}`. It omits
other language navigation in that isolated preview. With these options omitted,
the full-language delivery checks and assembly remain unchanged. Site assembly
uses `ffprobe` to show the duration of each bundled video in the gallery.

The current Korean editorial proposal is in `DemoLab/Edits/korean-review.json`.
Its portable media and preview commands are in `DemoLab/Edits/README.md`.
It retains camera provenance and exact source frame ranges. The representative
film ends after copying/pasting text; its departure-board sequence is absent.
The Live film ends after its second source caption. The other three films keep
their camera timelines. Editorial captions retain actual shortcut event times.
Approve Korean copy, structure and films before updating other language outputs
or replacing the complete publication media manifest.

For native UI review, pass `SWIFTYCROW_REVIEW_LOCALE=ko` as an Xcode build
setting. Both catalog validation and compiler-extracted string validation use
that explicit locale. This option is accepted only for Debug builds; release
builds retain the complete language gate. Omitting it keeps full validation.

See [the maintained Swift batch workflow](../DemoLab/docs/SWIFT-WORKFLOW.md) for recording/resume, explicit
take selection, contact sheets, export, review bundle merging, and verified asset
installation. The current complete bundle is `DemoLab/Edits/review-bundle.json`;
CI checks its portable evidence without requiring local camera originals.
