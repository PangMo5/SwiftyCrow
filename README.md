# SwiftyCrow <img src="Resources/Marketing/app-icon.png" align="right" height="128" />

[![Latest release](https://img.shields.io/github/v/release/PangMo5/SwiftyCrow?sort=semver)](https://github.com/PangMo5/SwiftyCrow/releases/latest)
[![Download](https://img.shields.io/github/downloads/PangMo5/SwiftyCrow/total)](https://github.com/PangMo5/SwiftyCrow/releases)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue)
[![License: MPL-2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen)](LICENSE)

On-screen translator for macOS, fully on-device. Captures any region of the screen with [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), recognizes text with [Vision](https://developer.apple.com/documentation/vision), and translates with the [Apple Translation](https://developer.apple.com/documentation/translation) framework — no cloud APIs, no keys, no quotas.

![SwiftyCrow demo](Resources/Marketing/demo.gif)

## Features

- **Lives in the menu bar** — no Dock icon; open the popover from the menu bar item, `⌘,` for Settings
- **Region capture** — drag to select any part of the screen (or press **Space** to highlight and click a whole window, like the macOS screenshot tool); it's translated and shown in a floating preview with each line **blurred** behind its translation. Save the image, copy it, or copy the original / translated text
- **Live overlay** — pick a target the same way (drag a region, or Space to click a window) and an overlay snaps onto it and keeps translating as the content changes. It always lets clicks and scrolling pass through to the app underneath; its built-in **LIVE** handle pauses/resumes and the **×** closes it. Show the translation **in place** over the source, or in a separate **window** while the overlay stays a thin region frame
- **Reads the layout** — recognition follows the document structure: vertical (top-to-bottom) Japanese/Chinese and multi-column text are read in reading order and the translation is laid out to match — vertical text stays vertical, in place over the original
- **Instant re-captures** — translating the same screen again is cached
- **Languages from your Mac** — source/target lists are the languages installed on your system; pick the pair that matches the text, or set the source to **Auto** to detect it per line (handy for mixed-language screens)
- **Customizable shortcuts** — capture, live overlay, pause/resume Live, display mode (In-place / Window), and the save/copy keys, all in Settings → Shortcuts
- **Launch at login** — start SwiftyCrow automatically when you log in (Settings → General)
- **Editable config file** — a plain-text file you can hand-edit, kept in sync with the in-app Settings

## Install

Requires **macOS 26+**.

**Homebrew** (recommended):

```sh
brew install --cask PangMo5/tap/swiftycrow
```

**Direct download**: grab the latest `.dmg` from the [Releases page](https://github.com/PangMo5/SwiftyCrow/releases/latest), open it, and drag the app to Applications.

On first launch, grant **Screen Recording** permission in System Settings → Privacy & Security, then relaunch the app. The app keeps itself up to date afterward.

## Usage

1. Pick the **Source** and **Target** languages in Settings (`⌘,`).
2. **Capture a region**: trigger **Capture Region** (the popover button or your hotkey), then drag over the text — or press **Space** to highlight and click a whole window. A floating preview window shows the translation over the screenshot — `⌘S` save, `⌘C` copy image, `⌘O` copy original, `⌘T` copy translation, `Esc` to close.
3. **Or use the live overlay**: trigger **Live overlay…** (menu bar or hotkey), then drag a region — or press **Space** to click a window — and an overlay snaps onto it and starts translating live. Use the **LIVE** handle to pause/resume, `⌘C` to copy the joined translation, and **×** to close.

All hotkeys are customizable in Settings → Shortcuts.

## Troubleshooting

### Translation says "Unable to translate" or shows a language error

SwiftyCrow uses Apple's on-device translation framework, which requires translation models to be installed for each language you translate. If translation fails, it's usually because the detected source language doesn't have a model installed yet.

**To install translation models:**

1. Open **System Settings** → **General** → **Language & Region**
2. Scroll down to **Translation** 
3. For each language you want to translate, click **Download** to install its model (1–3 GB per language)
4. Once downloaded, relaunch SwiftyCrow and try translating again

**Which languages do I need?**
- Install your source language (the language you're translating *from*, e.g., English if you're translating English text)
- Install your target language (the language you're translating *to*, e.g., Spanish if you want Spanish translations)
- If you use **Auto** source detection, make sure you have models installed for every language that might appear in your captures

**Note:** Translation models are managed by macOS and stored locally. If you're short on disk space, you can uninstall unused language models from the same Settings panel.

For more details, see [docs/LANGUAGE_MODELS.md](docs/LANGUAGE_MODELS.md).

## Configuration

Settings live in `~/.config/SwiftyCrow/config.toml`, grouped into tables that
mirror the in-app Settings tabs — `[capture]`, `[languages]`, `[overlay]`,
`[shortcuts]`, `[translation]`, and `[updates]`. Edits made in the app or by
hand are kept in sync.

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full reference —
every key, its default, and the shortcut syntax.

## Development

### Requirements

- macOS 26+
- Xcode 26+ / Swift 6.3+
- [mise](https://mise.jdx.dev) (manages Tuist + SwiftFormat versions via `.mise.toml`)

### Building from source

```sh
export TUIST_DEVELOPMENT_TEAM=YOUR_TEAM_ID   # your Apple Developer Team ID
mise install               # installs Tuist + SwiftFormat
tuist install              # resolves SPM dependencies
tuist generate             # generates the Xcode workspace
open SwiftyCrow.xcworkspace
```

`TUIST_DEVELOPMENT_TEAM` makes the Debug build sign with the same Apple
Development certificate every time. Skip it and macOS will treat each build
as a new binary and re-prompt for Screen Recording permission on every
launch. Persist it in your shell profile or in `~/.mise.local.toml`:

```toml
[env]
TUIST_DEVELOPMENT_TEAM     = "YOUR_TEAM_ID"
TUIST_SPARKLE_PUBLIC_ED_KEY = "YOUR_SPARKLE_PUBLIC_KEY"
```

`SPARKLE_PUBLIC_ED_KEY` is baked into `Info.plist` at generate time so the
app can verify update signatures. For local debug builds it can be empty.

### Tech stack

- **Tuist** generated workspace (`Project.swift`, `Tuist/Package.swift`)
- **TCA** (`swift-composable-architecture`) for app + capture state; dependencies wired with `@DependencyClient`
- **swift-sharing** with a `fileStorage` strategy bridged to **swift-toml**
- **Magnet** for global hotkey registration, plus a small custom recorder view
- **Sparkle** for in-app updates
- **Apple Vision** for OCR, **Apple Translation** for translation, **ScreenCaptureKit** for capture
- Source style enforced by the [Airbnb SwiftFormat](https://github.com/airbnb/swift) configuration in `.swiftformat`

## License

[Mozilla Public License 2.0](LICENSE). Originally MIT (2021); relicensed to MPL-2.0 in 2026.

MPL-2.0 is file-level copyleft: modifications to existing source files must remain under MPL-2.0, but you can add new files under any compatible license. App Store distribution is supported.
