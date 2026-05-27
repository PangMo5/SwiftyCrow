# SwiftyCrow <img src="Resources/Marketing/app-icon.png" align="right" height="128" />

On-screen translator for macOS, fully on-device. Captures any region of the screen with [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), recognizes text with [Vision](https://developer.apple.com/documentation/vision), and translates with the [Apple Translation](https://developer.apple.com/documentation/translation) framework — no cloud APIs, no keys, no quotas.

![SwiftyCrow demo](Resources/Marketing/demo.gif)

## Features

- **Menu bar agent** (`LSUIElement = true`) — no Dock icon; click the menu bar item for the popover and `⌘,` for Settings
- **In-place per-line translation** — each OCR line is replaced by its translation right on top of the source, sized to the original line height (Apple Translate camera mode style)
- **Floating overlay** as a transparent borderless `NSPanel` you can drag, resize, and auto-hide on hover; ⌘C copies the current translation
- **Live mode** re-captures the overlay region on a configurable interval; **`LIVE` badge** pulses while the loop runs
- **Per-line translation cache** keyed by `(source, target, strategy, text)` — repeat captures of the same screen skip the network/Apple-Intelligence call entirely
- **Auto source detection** via Vision's `automaticallyDetectsLanguage`; the detected `Locale.Language` is fed straight into `TranslationSession`
- **Dynamic language list** loaded from `LanguageAvailability().supportedLanguages` ∩ `RecognizeTextRequest.supportedRecognitionLanguages`
- **Global keyboard shortcuts**: Capture Once, Toggle Live Mode, Toggle Overlay (bound from Settings → Shortcuts)
- **Single TOML config** at `$XDG_CONFIG_HOME/SwiftyCrow/config.toml` (or `~/.config/SwiftyCrow/config.toml`), two-way synced with the in-app Settings UI

## Install

Requires **macOS 26+**. Install via the Homebrew tap:

```sh
brew install --cask PangMo5/tap/swiftycrow
```

On first launch, grant **Screen Recording** permission in System Settings → Privacy & Security, then relaunch the app. Sparkle keeps the app up to date afterward.

## Usage

1. Click the menu bar icon to open the popover, then pick **Source** (or leave **Auto**) and **Target** languages from Settings (`⌘,`).
2. Drag / resize the floating overlay to cover the region you want translated.
3. Press **Capture Once** from the popover or your bound hotkey, or flip **Live** to keep re-capturing.
4. The translated text appears directly over each recognized line. While the overlay window is focused: `⌘,` opens Settings, `⌘C` copies the joined translation.

Shortcuts are bound from Settings → Shortcuts.

## Configuration

All persisted settings live in a single TOML file:

```sh
${XDG_CONFIG_HOME:-$HOME/.config}/SwiftyCrow/config.toml
```

The file is written by the app and can also be edited by hand — changes are picked up on next launch. Example:

```toml
captureInterval = 0.8
overlayEnabled = true
overlayHideOnHover = false
ocrMode = "text"                 # "text" or "document"
translationStrategy = "lowLatency"  # or "highFidelity" (macOS 26.4+)

# Empty `code` on sourceLanguage means Auto — Vision detects it.
[sourceLanguage]
code = ""

[targetLanguage]
code = "ko-KR"

[overlayFrame]
x = 200.0
y = 200.0
width = 520.0
height = 280.0
```

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
TUIST_DEVELOPMENT_TEAM = "YOUR_TEAM_ID"
SPARKLE_PUBLIC_ED_KEY  = "YOUR_SPARKLE_PUBLIC_KEY"
```

`SPARKLE_PUBLIC_ED_KEY` is baked into `Info.plist` at generate time so the
app can verify update signatures. For local debug builds it can be empty.

### Tech stack

- **Tuist** generated workspace (`Project.swift`, `Tuist/Package.swift`)
- **TCA** (`swift-composable-architecture`) for app + capture state; dependencies wired with `@DependencyClient`
- **swift-sharing** with a `fileStorage` strategy bridged to **swift-toml**
- **KeyboardShortcuts** by sindresorhus for global hotkeys
- **Sparkle** for in-app updates
- **Apple Vision** for OCR, **Apple Translation** for translation, **ScreenCaptureKit** for capture
- Source style enforced by the [Airbnb SwiftFormat](https://github.com/airbnb/swift) configuration in `.swiftformat`

## License

[Mozilla Public License 2.0](LICENSE). Originally MIT (2021); relicensed to MPL-2.0 in 2026.

MPL-2.0 is file-level copyleft: modifications to existing source files must remain under MPL-2.0, but you can add new files under any compatible license. App Store distribution is supported.

## Credits

### App Icon
- Rendered with ChatGPT Image, 2026
