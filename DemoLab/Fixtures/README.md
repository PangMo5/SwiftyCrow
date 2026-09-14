# Original sources for five distinct demonstrations

The fixtures provide only foreign-language source pixels. SwiftyCrow performs
real recognition and translation while the camera records the desktop.

| Film | Source | Language |
| --- | --- | --- |
| `tour` | Harbor leaflet and a changing departure board | English |
| `capture` | Camera manual with a labeled diagram, numbered steps and caution | English |
| `live` | Animated educational MP4 with three changing captions | English |
| `layout` | Magazine photo, horizontal headings, eight vertical body columns and inset note | Japanese |
| `compare` | Interactive pixel-art game with two dialogue states | English |

`scenarios.json` declares each source, native window geometry, selection area,
expected source/translation fragments and the Japanese body reading order.
`manifest.json` hashes all source inputs and generators. Rebuild the manifest
after intentional source changes and record new takes.

Build the sources with the Swift programs documented in
[ASSET-SOURCES.md](ASSET-SOURCES.md). The independent native `DemoScenes.app`
uses AppKit and AVPlayerView to show the game, departure board and actual MP4.
It does not link SwiftyCrow, provide OCR results, inject translations or write
clipboard output. Native paste destinations receive the real app's clipboard.

All five UI locales use the same source language for a given film. UI localization
does not change the input material. Earlier guide/comic rehearsal inputs are
preserved with their manifest under
`DerivedData/QA/diverse-demos-2026-09-11/previous-fixtures/`.
