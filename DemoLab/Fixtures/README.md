# Original inputs for page-language demos

The fixtures contain only authored source material. SwiftyCrow recognizes and
translates their rendered pixels while the camera records the desktop.

The current [scenario matrix](../Scenarios/localized-2.10.json) requires the actual
translation target to match the page language, including Chinese script variants.
UI and caption localization alone is insufficient.

| Page | Tour, manual, video, game inputs | Magazine input | Translation output |
| --- | --- | --- | --- |
| English | Korean | Japanese | English |
| Korean | English | Japanese | Korean |
| Japanese | English | Traditional Chinese | Japanese |
| Simplified Chinese | English | Japanese | Simplified Chinese |
| Traditional Chinese | English | Japanese | Traditional Chinese |

`LocalizedSources/ko/` holds the authored Korean leaflet, manual, science movie,
and source-text catalog used by the independent game renderer.
`LocalizedSources/zh-Hant/` holds the Chinese magazine used for the Japanese page.
The baseline English/Japanese artwork remains unchanged for the approved Korean
recordings. Original game/background photographs are shared across inputs.

The source application only displays original content through AppKit and
AVPlayerView. It never supplies OCR, translation, or clipboard results. Use
`--source-language ko-KR` for its Korean movie/game sources and `en-US` for the
baseline sources. `manifest.json` hashes the assets and generator sources.

Example source generation:

```sh
swift DemoLab/Fixtures/GenerateScenarios.swift --output DemoLab/Fixtures/LocalizedSources/ko --images travel-leaflet.png,camera-manual.png --source-language ko-KR --text-catalog DemoLab/Fixtures/LocalizedSources/ko/source-text.json
swift DemoLab/Fixtures/GenerateScienceVideo.swift --output DemoLab/Fixtures/LocalizedSources/ko/science-light.mp4 --text-catalog DemoLab/Fixtures/LocalizedSources/ko/source-text.json
swift DemoLab/Fixtures/GenerateScenarios.swift --output DemoLab/Fixtures/LocalizedSources/zh-Hant --images chinese-magazine.png --magazine-name chinese-magazine.png --source-language zh-Hant --text-catalog DemoLab/Fixtures/LocalizedSources/zh-Hant/source-text.json
```

Refresh the source manifest after intentional source changes. Preserve each
recorded source-manifest snapshot rather than pretending older takes used new
assets. The earlier fixed-pair `scenarios.json` and departure scene remain only
for reproducing previous recordings; new localized recordings use the matrix.
