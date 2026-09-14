# SwiftyCrow Demo Lab

Internal recording and review guidance. Keep this README and `docs/` in English.
The app, film titles, and film captions support `en`, `ko`, `ja`, `zh-Hans`, and
Taiwan-centered `zh-Hant`, following [LOCALIZATION.md](../docs/LOCALIZATION.md).

Five distinct films show a harbor trip, a camera manual, an educational video,
a Japanese magazine with vertical text, and an interactive game conversation.
A real SwiftyCrow Debug build runs in a dedicated Tart macOS guest. Preview and
the independent DemoScenes app display original source pixels; Vision recognizes
them and Apple Translation produces Korean text. TextEdit and Preview receive
real clipboard output. No OCR result, translation result, or product state is
injected.

- `Localization/Films.json`: complete film titles and captions for all five locales.
- `Localization/Narration.json`: localized chapter titles and step captions burned
  into the films. Shortcut badges come from the actual input timeline.
- `Fixtures/`: original raster documents, source movie, game artwork, independent
  native source app, scenario definitions, and a SHA-256 manifest. Magazine text
  is Japanese; the other source content is English in every app UI locale.
- `source-sample.html`: legacy smoke-test source for the original UI collection
  runner; it is not an input to the current feature films.
- `Recorder/`: Swift recording and native input tools, derived from Tatami's
  Demo Lab working tree. It exposes `DemoRecorder`, `demokey`, `ui-probe`, and
  the SwiftyCrow scene runner `demoqa`, plus local `HostRecorder`, `RecorderRelay`
  and `HostMouseRelay` tools for native host capture with measured clock alignment.
- `../Tools/`: Swift localization, full-frame video auditing, export verification,
  and website assembly. No Python or Node automation runtime is required.
- [Recording and review](docs/RECORDING.md): VM ownership, permissions, reproduction,
  visual review, and the evidence boundary.
- [Reading scenarios](docs/SCENARIOS.md): the product purpose, continuous tour,
  focused feature films, and the visible outcome each must establish.
- [Media provenance](media-manifest.json): selected camera originals, app snapshot,
  source hashes, recording metrics, and publication asset hashes.

The website introduces screen translation, then groups recordings by capability.
The Korean editorial review is in `Edits/README.md`; its live subtitle and game
recordings are examples of translating changing screen text, not the scope of
the feature. Describe capture as selecting a screen region or window, and live
translation as following text changes inside that selection. Keep scene-specific
language in individual demo descriptions. The builder selects the matching
recording for each page language; generated README files share the feature
organization and localized demo links.

```sh
swift run --package-path Tools swiftycrow-tools check
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools site --output DerivedData/LocalizedSite
swift test --package-path Tools
```

Run these commands from the repository root. Camera originals, full screenshots,
AX snapshots and guest logs stay in ignored `DerivedData/QA/`; only reviewed
MP4/poster exports and their provenance belong in `web/media/`.

Exports also retain the exact ASS subtitle sidecar. Install FFmpeg with libass
and select it through `SWIFTYCROW_FFMPEG` when it is not the default `ffmpeg`:

```sh
export SWIFTYCROW_FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
```

The encoder preserves every frame, the full desktop and the take's timing.
Top corners hold chapter and actual shortcut badges; the bottom margin holds
two-line stage captions. Global capture/live shortcuts are assigned in Settings
for recording and are described as assigned shortcuts, not app defaults.
