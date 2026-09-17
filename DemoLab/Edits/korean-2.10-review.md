# Korean 2.10.0 demo recordings

The Korean review uses fresh recordings of SwiftyCrow 2.10.0 from app commit
`defbee7`. The archive, executable, catalog, fixture, scenario, recorder, and
input-runner hashes are retained in the review manifest and original `scene.json`
files. Other locales remain at the previous review stage.

Recording uses the owned `swiftycrow-demo` VM at 1920 × 1200, 30 fps, HEVC.
The camera runs inside the guest; host window geometry and host app switching do
not alter the captured desktop. Audio is disabled. All actions operate real app
controls, installed Apple translation models, and the actual system clipboard.
No source/result injection, UI pixel replacement, cuts, speed changes, or removed
translation waits are used. H.264 exports retain each original frame and duration.

The guest's screen-access prompt was allowed after explicit user approval. Tips
notifications were disabled in guest System Settings. The pointer is parked away
from controls and preparation windows settle before the camera starts. Earlier
rehearsals are retained as rejected takes because an unrelated Tips banner was
visible at their opening. They are not used in the final review media.

The `final-01` takes are checked through recorded Accessibility snapshots,
clipboard assertions, complete frame decoding, opening frames, and sampled
full-desktop contact sheets. Captioned exports are separately inspected at full
resolution. Raw evidence is under
`DerivedData/QA/tart-share/korean-retake-20260915/ko/`; audit output is under
`DerivedData/QA/korean-retake-20260915/review/`.

Verified workflows:

- Tour: use the new capture button, translate the selected text, copy the actual
  translation, and paste it into TextEdit.
- Capture: translate the camera manual, copy the full image, and open it in
  Preview while preserving the diagram, numbered steps, and caution.

- Live: choose the video area with the menu button, play the real source movie,
  and observe both translated phases in the same region.
- Layout: translate mixed horizontal/vertical Japanese text and verify that
  Copy Original preserves the specified reading order when pasted into TextEdit.

- Compare: select the game dialogue area, switch to a separate translation
  window, advance the actual scene, hide translation with the switch, and restore
  the same saved region. The prepared and restored window frames match exactly.

Final original cadence: tour 627 frames / 0 missed slots; capture 612 / 0;
live 616 / 0; layout 662 / 2 (0.301% of 664 slots); compare 872 / 0.
All are inside the 1% gate and decode at the original 1920 × 1200 dimensions.
The two missed layout slots remain visible in the unretimed original and export.

Playback verification passed 20 checks: all five films in Chromium and WebKit,
each at desktop (1440 × 1000) and mobile (390 × 844) sizes. Every film loaded at
1920 × 1200, played, sought to its end, and matched its expected duration.
Gallery keyboard navigation, exclusive playback, page errors, and horizontal
overflow checks passed. Captioned posters and the mobile gallery were inspected.
Results: `DerivedData/QA/korean-retake-20260915/playback-results.json`.

Narration and media-provenance tests passed (5 tests, including 20 parameterized
cases). Korean app/document/web catalog checks passed. Original/export and
manifest hashes were independently rechecked for all five movies.

The filming VM was shut down normally after copying the recordings. Temporary
host recorder/input services were stopped; no persistent host tiling changes
were retained. This is a local Korean review checkpoint, not a published release.
