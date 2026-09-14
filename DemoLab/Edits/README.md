# Korean editorial review checkpoint

The Korean review media in `media/ko/` retain the movie, poster, ASS captions,
metadata, and narration timeline matching `korean-review.json`. They are distinct
from the earlier full-language exports in `web/media/` and their publication
manifest. Camera originals remain in ignored QA storage; their hashes and source
frame ranges are retained in the review manifest.

Rebuild this checkpoint from the repository root:

```sh
swift run --package-path Tools swiftycrow-tools docs --locale ko
swift run --package-path Tools swiftycrow-tools check --locale ko
swift run --package-path Tools swiftycrow-tools site --locale ko --media-root DemoLab/Edits/media --output DerivedData/KoreanReview
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/KoreanReview --port 8766
```

Use another port if a preview server is already running. FFmpeg/ffprobe must be
available for site assembly. Open `/ko/` in the preview server.

The website uses a two-video Live gallery ported from Tatami, with desktop
side navigation and mobile tabs above the player. The README uses factual
feature groups while the website introduces use cases.

Only Korean text outputs have been regenerated for this editorial pass.
Full-language validation and app build scripts deliberately still require the
remaining translations; they are not a passing delivery gate at this checkpoint.
The localized repository-document test remains pending for the same reason.

Validation at this checkpoint: release build of SwiftyCrowTools, 22 focused tool
tests, Korean catalog/generated-document checks, and 20 video playback checks
across desktop/mobile WebKit and Chromium. Gallery paging, keyboard navigation,
hash links, and exclusive playback were also verified. No app build or tests
were repeated for the final web/README edit.
