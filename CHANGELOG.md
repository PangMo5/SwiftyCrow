# Changelog

All notable changes to SwiftyCrow. This file is the source of truth for the
release notes shown on the website and on GitHub Releases (the release workflow
appends an Install / Update section when publishing).

## 2.3.0 — 2026-06-01

### What's New

- **Pass-through mode.** A new toggle (Settings → Overlay) and global shortcut let the overlay forward all mouse interaction — clicks, scrolling, dragging — to the apps below it, while the translation stays on top. You can still resize it from the edges and drag it by the top-right badge; the border turns accent-colored and a PASS-THROUGH badge shows while it's on.

### Changed

- **The idle guide shows once per enable.** It appears when you turn the overlay on, then stays out of the way — toggling Live on and off just leaves a transparent frame instead of bringing the guide back.

### Fixed

- **Multi-monitor region capture.** The selector now opens on the screen under the cursor, so the selection and capture target the display you're actually pointing at instead of spanning all of them.

## 2.2.2 — 2026-05-29

### Performance

- **Region capture no longer stalls while blurring.** The blurred backdrop is now built with thread-safe Core Graphics / Core Image off the main thread, so the result window stays responsive while the gaussian blur and per-box compositing run.
- **Faster translation.** All lines are translated in a single on-device translation session (batched) instead of spinning up one session per line; results still stream in progressively, chip by chip.
- Fixed a case where the translating spinner could stay spinning if a translation errored.

## 2.2.1 — 2026-05-28

### Fixed

- **Saved/copied capture images are now at the original screenshot's resolution.** Previously the screen-capture path was bounded by the on-screen window size, so tall captures the window had to shrink were saved at lower resolution. The window now briefly resizes to 1:1 with source pixels for save/copy, then restores.

## 2.2.0 — 2026-05-28

### Highlights

- **Region capture now matches the live overlay.** Translation chips render as the same Liquid Glass over a blurred backdrop; save and copy use the on-screen result so the image you keep matches what you saw.
- **Smarter sentence stitching.** OCR lines that are part of one wrapped sentence are merged before translation (trimmed, language-aware joining, no more chopped per-line boxes).
- **Launch at Login.** A new *General* tab in Settings registers SwiftyCrow as a login item via `SMAppService`.
- **About tab.** Version, author, GitHub link, and open-source credits.
- **Sparkle update notes.** The update prompt now links to each release's notes on GitHub.

### Docs

- Configuration reference moved out of the README into [`docs/CONFIGURATION.md`](https://github.com/PangMo5/SwiftyCrow/blob/main/docs/CONFIGURATION.md) — every key, default, and the shortcut syntax in one place.

## 2.1.0 — 2026-05-27

### What's New

- **Region capture** — drag to select any area of the screen; it's OCR'd and translated, then shown in a borderless preview window with each line's box **blurred** and the translation drawn on top. `⌘S` saves a PNG (timestamped), `⌘C` copies the image, `⌘O`/`⌘T` copy the original/translated text, `Esc` closes.
- **Customizable shortcuts** — Capture Region / Toggle Live / Toggle Overlay (global) plus the result-window Save/Copy keys, all set in **Settings → Shortcuts**.
- **Sectioned config** — `config.toml` is now grouped into `[capture]`, `[languages]`, `[overlay]`, `[recognition]`, `[shortcuts]`, `[translation]`, `[updates]`, mirroring the Settings tabs. Window geometry moved out of config into Application Support.
- **Explicit source language** — the "Auto" source option was removed; pick the language that matches the text (defaults to English).

## 2.0.0 — 2026-05-27

### Highlights

- **In-place per-line translation** — each recognized line is replaced by its translation on top of the source, sized to the original line height (Apple Translate camera mode style).
- **Floating glass overlay** — a transparent, borderless panel you can drag, resize, and auto-hide on hover. `⌘C` copies the current translation.
- **Live mode** — re-captures the overlay region on an interval, with a pulsing `LIVE` badge while running.
- **Menu bar agent** — no Dock icon; global shortcuts (Capture Once, Toggle Live, Toggle Overlay) work even with no window open.
- **Auto source detection** via Vision, **dynamic language list** from the installed Apple Translation + OCR languages — nothing hardcoded.
- **Per-line translation cache** so repeat captures of the same screen skip the translation call.
- **Single TOML config** at `$XDG_CONFIG_HOME/SwiftyCrow/config.toml`, two-way synced with the in-app Settings.

### Under the hood

- 100% on-device: ScreenCaptureKit + Vision OCR + Apple Translation.
- Built for **macOS 26+** with the modern `SCScreenshotManager`, `RecognizeTextRequest`, and direct `TranslationSession` APIs.
- Sparkle-powered automatic updates.
