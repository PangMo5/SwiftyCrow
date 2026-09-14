# Distinct uses of SwiftyCrow

The current Korean editorial review is defined in `../Edits/korean-review.json`.
The contracts below describe the preserved camera originals. The Korean review
uses only the capture/copy/paste prefix of `tour` and ends `live` after the second
caption; the website groups `compare` under Live. Other language edits wait for
Korean approval. Keep these original fixture contracts intact for provenance.

## Product point of view

SwiftyCrow translates pixels in the app a person is already using. The hero
film should make that useful in one coherent task. Each focused film should
then answer a different practical question. Repeating the same page and comic
with another toolbar button does not demonstrate a different use.

The five scenes therefore have separate content, settings, visual treatments,
and outcomes. The tour is a travel-planning story. The focused films cover a
technical instruction sheet, a playing video, a mixed-direction magazine page,
and an interactive game. Zoom and Fit remain preparation details.

## Film contracts

| Film | Actual situation | Source | Sequence and distinct outcome |
| --- | --- | --- | --- |
| `tour` | Plan a harbor visit and react to a changed boarding location | An illustrated tourist leaflet in Preview; a native departure board | Capture visiting information, paste the real translated text into a TextEdit itinerary, then translate the board live. The board changes from the east pier to the west pier without another region selection. This film follows a person's task across apps. |
| `capture` | Keep a usable translated instruction sheet | A camera quick-start image with a labeled drawing, numbered instructions and a caution | Translate the sheet, use Copy Image, and open the actual clipboard image in Preview. The drawing, callouts and warning remain attached to the instructions. |
| `live` | Follow changing subtitles while a video keeps playing | An original 24-second MP4, played through native AVPlayerView | Select the burned-in subtitle area once; play the video; observe three successive captions and their translations while the illustration continues to move. This film tests time-varying pixels and stale-result replacement. |
| `layout` | Read a page whose directions and blocks differ | A raster Japanese magazine with a horizontal title, eight vertical body columns, a photograph and its caption and an inset note | Translate the actual page. Copy the recognized original into TextEdit and inspect the body in reading order. Check direction, paragraph grouping, character accuracy and rendered placement independently. |
| `compare` | Understand game dialogue without covering the scene | An original interactive pixel-art game scene in a separate native source app | Select the dialogue, switch translation to its own window beside the game, and click Continue to advance the source dialogue. Hide and recall translation on that same region. The game artwork and controls remain usable. |

`Fixtures/scenarios.json` defines source language, source application, verified
selection geometry, expected content and native window arrangement for each
film. Geometry is finalized from native accessibility and screenshots during
rehearsal. `Fixtures/scenario-content.json` retains the complete Japanese source
body for a character-level comparison. The recognition film translates Japanese
to Korean; the other films translate English to Korean. App interface languages
are independently recorded for English, Korean, Japanese, Simplified Chinese
and Traditional Chinese for Taiwan.

## Honest source content

All source material is original fictional demonstration content. Native Preview
shows raster documents. `DemoScenes.app` is an independent source application:
it draws a departure board and a small dialogue game, or plays the actual source
MP4 with AVPlayer. It has no integration with SwiftyCrow, OCR, translation or the
clipboard. Its Play, Continue and Restart controls affect only its own source
content. The source movie contains only English captions.

The app's screenshots, OCR output, translation, clipboard and live-overlay state
must come from the real SwiftyCrow build. Do not synthesize translation output,
insert translated text into a note, edit a failing frame, or turn prepared source
screens into a fake product recording. Keep source-video generation separate
from the final native screen recorder.

## Acceptance before recording every locale

1. Review one native rehearsal of each distinct situation before recording any
   language batch. Titles and captions must describe the behavior actually shown.
2. For recognition, inspect the original page, actual copied original text, and
   translated rendering together. Compare vertical-body order independently of
   isolated character errors. Record mismatches explicitly; never silently alter
   the source or expected result to disguise an OCR error.
3. For dynamic content, record the previous and next source states, the resulting
   translations, and proof that the region was not selected again. A paused or
   static source does not establish live behavior.
4. Copy Translation and Copy Image must use the real guest clipboard. Keep Tart
   clipboard sharing disabled. Prepare only an empty insertion point and a note
   heading, never translated content.
5. Place the separate translation window in the free space beside the game;
   verify that the source remains usable when advancing dialogue.
6. Establish readable source scale and close unrelated windows before a take.
   Freeze assets, contracts, app archive and runner provenance after rehearsals.
7. Preserve rejected takes separately. Review every final camera timeline,
   independent screenshots, and exported transitions under RECORDING.md. Do not
   reuse a film under another feature's ID or language.

The website and all READMEs share these five contracts. Privacy remains factual
supporting information rather than a staged network-audit animation. A demo is
bounded evidence for its visible scene, not a universal OCR benchmark.
