# Changelog

All notable changes to SwiftyCrow. This file is the source of truth for the
release notes shown on the website and on GitHub Releases (the release workflow
appends an Install / Update section when publishing).

## 2.6.1 — 2026-06-13

### Fixed

- **Recording a shortcut no longer fires other shortcuts.** While the recorder is capturing, all global hotkeys are suspended — so pressing a combo that's already bound (e.g. your capture key) records it instead of triggering that action.

## 2.6.0 — 2026-06-13

### What's New

- **Pick a window like the macOS screenshot tool.** While selecting a region, press **Space** to switch to window mode — the window under the cursor highlights and a click selects it. Region capture then grabs just that window (occlusion-independent); the live overlay snaps exactly onto it. Works across every display.
- **Drag-to-select live overlay.** Starting a live overlay now works just like a region capture: trigger **Live overlay…** (menu bar or shortcut), drag a region (or Space to pick a window), and an overlay snaps onto your selection and starts translating live immediately. No more "enable the overlay, position the floating panel, then turn on Live."
- **Built-in overlay controls.** The overlay carries an always-visible **LIVE** handle (coloured while live, monochrome when paused — click to toggle) and an **×** button to close it.

### Changed

- **The overlay is always click-through.** Whenever a live overlay is on screen it lets clicks and scrolling pass through to the apps below; grab the LIVE handle to move it, the edges to resize it. There's no longer a persistent, manually-positioned overlay or an idle guide — the overlay exists only while a live session is placed.
- **Reworked the shortcut recorder.** A new recorder field (matching the app's Liquid Glass) shows shortcuts with stable English glyphs (e.g. `⌘S`) regardless of the active keyboard layout, records on a single click, flags a combo that's already in use, and clears with a dedicated button. The capture-window Save/Copy keys now live in `config.toml`'s `[shortcuts]` table (with `⌘S`/`⌘C`/`⌘O`/`⌘T` defaults) instead of being stored separately. Global hotkeys are now registered with **Magnet**.

### Breaking Changes

- **`[shortcuts] toggleOverlay` is renamed to `liveOverlay`.** It now starts/replaces the live overlay by selecting a region (Space to pick a window). An old `toggleOverlay` entry in `config.toml` is ignored — re-add your binding under `liveOverlay` (or in Settings → Shortcuts).
- **`[overlay] enabled` is removed.** The overlay no longer has a persistent on/off; you place it by selecting a region/window and close it with the overlay's **×** button. The key is ignored if present.

## 2.5.0 — 2026-06-09

### What's New

- **Window live mode.** Live translation can now show in a separate, live-updating window while the overlay stays a thin region frame — so the source app underneath stays visible and usable. Switch between **In-place** and **Window** in the popover, Settings → Overlay, or with the new "Toggle live mode" shortcut.
- **Pass-through is automatic.** Once a translation is on screen, clicks and scrolling pass through to the app underneath (edges still resize, the badge still drags). No more toggle — only the idle guide stays interactive.

### Changed

- **Redesigned menu bar popover** — a compact control panel: Capture Region, an Overlay section (show / Live / display mode), and a slim footer. The old Recognized/Translated text panels are gone.
- **Refreshed the idle overlay guide** with a cleaner, centered card.

### Fixed

- The "Check for Updates" buttons could stay disabled; updater availability now stays current.

## 2.4.1 — 2026-06-02

### Fixed

- **Stable `config.toml` ordering.** The config file's sections and keys were written in a non-deterministic order, churning the file on every change. Keys are now written sorted, so edits produce clean, minimal diffs.

## 2.4.0 — 2026-06-02

### What's New

- **Auto source language, now the default.** SwiftyCrow detects the language to translate from instead of you picking it. Detection is per line — on a mixed-language screen each line is translated from its own language, with a whole-capture fallback for short or ambiguous lines — and lines already in your target language are left as-is. Pin a specific source any time in Settings → Languages.

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
