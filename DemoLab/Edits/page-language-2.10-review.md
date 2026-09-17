# Page-language demo correction for 2.10.0

The earlier multilingual recordings localized UI and captions while keeping the
translated output in Korean. That did not meet the requirement and those twenty
movies are rejected. Their original evidence and exports are preserved in
`DerivedData/QA/locale-output-2.10/rejected-ui-only/`.

These replacement recordings require the actual translated output to match the
page language. `DemoLab/Scenarios/localized-2.10.json` defines the source and target
for every locale and film; `Films.json` declares the same pairs for exports.

| Page | Tour, capture, live, compare | Layout |
| --- | --- | --- |
| English | Korean → English | Japanese → English |
| Korean (unchanged) | English → Korean | Japanese → Korean |
| Japanese | English → Japanese | Traditional Chinese → Japanese |
| Simplified Chinese | English → Simplified Chinese | Japanese → Simplified Chinese |
| Traditional Chinese | English → Traditional Chinese | Japanese → Traditional Chinese |

The source images and source movie are authored material, rendered before the
app sees them. The independent source app only displays source content. Actual
recognition, translation, clipboard copies, and rendering are performed by
SwiftyCrow. Translation results are never supplied by the fixture generator.

The runner rejects a target language/script different from the UI language and
compares complete localized source/target picker values. Export and site assembly
also reject language-pair mismatches. Regression tests cover Korean output behind
other UI locales, Chinese script mismatches, region aliases, and source/target
identity. Translation assertions read full AX values rather than truncating long
paragraphs to 180 characters.

The first Chinese magazine source used a dense serif layout that produced OCR
errors and split a paragraph around a heading. That take was rejected. A shorter
article, clear sans-serif text, and separated headings produced the intended
source text and continuous body reading order in a new real capture. This is
source preparation, not a claim that all OCR errors are fixed.

All camera originals retain the complete 1920 × 1200 desktop at 30 fps, with no
cuts, speed changes, replacement application pixels, or removed processing waits.
Accepted takes must pass the 1% missed-slot gate and full video decoding. Layout
films deliberately copy *original* foreign text when demonstrating reading order;
the translated image shown before that step uses the page language.

All twenty replacement originals have now passed their assertions and visual
workflow review. Actual translated strings were collected from the app's recorded
accessibility output in `actual-language-evidence.json`; English, Japanese,
Simplified Chinese, and Traditional Chinese output was checked independently of
editorial captions. Simplified/Traditional-specific words and complete picker
labels also distinguish the two Chinese variants.

Final validation:

- All 20 replacement takes passed the 1% missed-slot gate. Nineteen had no
  missed slots; English compare had one missed slot out of 866 (about 0.12%).
- All 25 videos passed 100 playback checks: five locales, five films, Chromium
  and WebKit, and desktop/mobile viewports. Checks cover output language,
  current media hashes, playback, seeking, exclusive playback, keyboard gallery
  navigation, and page overflow.
- All 27 tool tests in seven suites passed. Catalog and generated-document
  checks passed. A negative site-build check rejected the old Japanese demo
  containing Korean output with `Demo result language does not match the page`.
- Korean movie, poster, caption, and timeline hashes match the approved Korean
  review. No Korean demo was re-recorded for this correction.
- The recording VM was shut down normally. The local review is served from
  `DerivedData/PageLanguageReview`; publication assets have not been promoted.

Detailed logs and playback results are under
`DerivedData/QA/locale-output-2.10/`. Earlier app tests were not rerun for this
media/tooling correction.
