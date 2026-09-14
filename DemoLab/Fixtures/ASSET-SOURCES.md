# Original source assets

These are fictional examples for native screen-translation demonstrations.
They contain no translation output and no borrowed product or game interface.

| Asset | Source and intended use |
| --- | --- |
| `travel-leaflet.png` | Deterministic AppKit drawing from `GenerateScenarios.swift`; a fictional harbor itinerary and map. |
| `camera-manual.png` | Deterministic AppKit drawing from `GenerateScenarios.swift`; a fictional camera instruction sheet and diagram. |
| `japanese-magazine.png` | AppKit and Core Text from `GenerateScenarios.swift`; original Japanese prose typeset vertically with horizontal supporting blocks. Exact text is in `scenario-content.json`. |
| `riverside-bookshop.png` | Original generated editorial photograph embedded in the Japanese magazine; no translated text or product output. |
| `science-light.mp4` | `GenerateScienceVideo.swift`; 24 seconds of animated source diagrams and three burned-in English captions, encoded to H.264. |
| `glass-observatory.png` | Original image generated with the built-in image-generation tool. Only background art; the independent source application renders all game dialogue and interaction in code. |
| `DemoScenes.swift` | Native AppKit source application for the departure board and interactive game, plus an AVPlayerView for the source movie. Build with `BuildDemoScenes.swift`. |

## Image-generation prompt

Built-in image generation, September 11, 2026. Saved project asset:
`DemoLab/Fixtures/glass-observatory.png`.

> Create a finished original widescreen pixel-art background for a small playable narrative game demo. Scene: an overgrown stone observatory perched on a grassy seaside cliff at blue hour, a young traveler carrying a rolled map at left and an older observatory keeper with a lantern at right, looking toward a half-open brass observatory door, luminous turquoise sea and a tiny island lighthouse in the distant horizon. Rich handcrafted pixel art, charming large coherent pixel clusters, restrained palette of midnight blue, teal, moss green and warm amber light, clear silhouettes. Camera shows the whole game scene in a side-on 2D adventure view, environmental storytelling. Width-to-height ratio 16:10. Reserve the bottom 22 percent as darker quiet ground with very little detail because a real dialogue UI will be drawn there in code later. Do not draw any dialogue boxes, letters, text, numbers, logos, watermarks or UI. This is only the art background for an original fictional game called The Glass Observatory; do not imitate a known game or artist.

Built-in image generation, September 11, 2026. Saved project asset:
`DemoLab/Fixtures/riverside-bookshop.png`.

> Use case: photorealistic-natural. Asset type: a single editorial photograph used inside an original Japanese walking magazine page. Create a richly detailed realistic travel photograph of a quiet old Japanese riverside bookshop after rain: low weathered timber building with one broad warmly lit window and books visible inside, a stone footpath beside a narrow river, moss and leafy branches, a small footbridge further along the water, soft late-afternoon sky reflections. Landscape 3:2 composition, natural 35mm photography, restrained warm-paper muted green palette, authentic material texture and calm everyday atmosphere. Photograph only, no page layout, no overlaid text, no readable signage, no logos, no watermarks. Do not imitate a specific known place or photograph.

The initial geometric building illustration caused real OCR false positives and
visible masking damage. That rejected input and camera evidence remain under
`DerivedData/QA/diverse-demos-2026-09-11/` and
`DerivedData/QA/tart-share/scenario-redesign-probe-01/`. Replacing the editorial
asset does not establish a product fix or universal OCR accuracy.

## Reproduction

```sh
swift DemoLab/Fixtures/GenerateScenarios.swift
swift DemoLab/Fixtures/GenerateScienceVideo.swift
swift DemoLab/Fixtures/BuildDemoScenes.swift /absolute/output/DemoScenes.app
open -na /absolute/output/DemoScenes.app --args --scene game --fixtures /absolute/path/SwiftyCrow/DemoLab/Fixtures
```

Source artwork is distinct from the final camera recording. Generators may
prepare only the foreign-language source; they must not generate product output.
Earlier `reading-guide.png` and `the-last-tram.png` assets are archived in
`DerivedData/QA/diverse-demos-2026-09-11/previous-fixtures/`. They are not part of
the current five scenarios or manifest.
