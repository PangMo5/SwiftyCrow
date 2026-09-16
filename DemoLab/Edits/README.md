# 2.10.0 multilingual review checkpoint

`media/` contains the movie, poster, ASS captions, metadata, and narration timeline
for five demos in each of English, Korean, Japanese, Simplified Chinese, and
Traditional Chinese. `multilingual-review.json` covers all 25 videos. The approved
Korean movies are preserved exactly; the other 20 were freshly recorded with the
localized app UI, editorial captions, and actual translation output matching
each page language. The scenario matrix is in `../Scenarios/localized-2.10.json`.

The Korean and multilingual app archives are distinct resource builds from the
same application source. Each recording retains its own archive/catalog hashes.
Korean app strings and narration values were compared and remain unchanged. See
[the page-language review](page-language-2.10-review.md) and
[the Korean review](korean-2.10-review.md) for evidence and scope.

Rebuild and serve this checkpoint from the repository root:

```sh
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools check
swift run --package-path Tools swiftycrow-tools site --media-root DemoLab/Edits/media --output DerivedData/PageLanguageReview
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/PageLanguageReview --port 8765
```

Use an available port if another server is running. FFmpeg/ffprobe must be
available. English is at `/`; other pages are at `/ko/`, `/ja/`, `/zh-Hans/`, and
`/zh-Hant/`. All locales have the two-video Live gallery with desktop side
navigation and mobile tabs. The README retains factual feature groups while the
website introduces usage examples.

This is a local review checkpoint, separate from the prior publication media and
manifest in `web/media/` and `DemoLab/media-manifest.json`. No release was published.
Camera originals and detailed runtime evidence remain in ignored QA storage.

Validation for this correction: 27 tool tests pass, and catalogs and generated
localized documents validate. All 20 replacement takes passed runtime assertions,
full decoding, and visual review. All 25 demos passed 100 playback checks across
Chromium/WebKit and desktop/mobile sizes, including per-page output-language and
media hash checks. Earlier app validation passed 230 tests; app tests were not
rerun for this media/tooling correction.

See [the maintained Swift batch workflow](../docs/SWIFT-WORKFLOW.md) for recording/resume, explicit
take selection, contact sheets, export, review bundle merging, and verified asset
installation. The current complete bundle is `DemoLab/Edits/review-bundle.json`;
CI checks its portable evidence without requiring local camera originals.
