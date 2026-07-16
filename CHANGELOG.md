# Changelog

All notable changes to SwiftyCrow. This file is the source of truth for the
release notes shown on the website and on GitHub Releases (the release workflow
appends an Install / Update section when publishing).

## 2.8.0 (2026-07-15)

### What's New

- **Predefine an area and translate it on demand.** The live overlay now remembers its region, so a new **Show / hide overlay** shortcut, or the menu bar's **Show on last region** / **Hide overlay** row, flips the overlay on and off over that same spot without dragging again. Ideal for a game panel or a fixed HUD you only glance at now and then. Turning it off tears the overlay down completely, so no capture, OCR, or translation keeps running until you bring it back. Bind it under `[shortcuts] toggleLiveOverlay` or in Settings → Shortcuts. (#9)

### Changed

- **Redesigned Settings.** Settings now opens as a standard, resizable window with a System-Settings-style sidebar: panes on the left and one grouped form on the right. It also comes forward as a regular app window while open.
- **Tidier live overlay.** The **LIVE** toggle and **×** close button now appear only when the pointer is over the overlay, matching the move handle. The progress spinner covers capture and OCR as well as translation, so a slow first capture shows activity immediately.

## 2.7.0 (2026-06-18)

### What's New

- **Vertical text is translated in place.** Vertical CJK passages, including Japanese and Traditional Chinese, are recognized in reading order and translated with characters stacked top-to-bottom, columns ordered right-to-left, and the source font scale preserved.
- **Structure-aware recognition.** Recognition groups text into reading-order paragraphs, separates ruby (furigana) from the annotated body, and detects each block's direction. Busy pages such as comics and multi-column layouts come out far cleaner.

### Fixed

- **A missing language model now tells you what to do.** When the captured language model is missing, SwiftyCrow shows a "Translation model not installed" hint in region results, the live overlay, window-mode results, and the menu bar. **Open Settings** jumps to the download location, while **Don't show again** dismisses the reminder.

### Changed

- **The Text / Document recognition toggle is gone.** Recognition always uses document layout analysis now. A `[recognition]` table in `config.toml` is ignored.

## 2.6.1 (2026-06-13)

### Fixed

- **Recording a shortcut no longer fires other shortcuts.** While the recorder is capturing, all global hotkeys are suspended, so pressing a combo that's already bound (e.g. your capture key) records it instead of triggering that action.

## 2.6.0 (2026-06-13)

### ⚠️ Breaking Changes

- **`[shortcuts] toggleOverlay` is renamed to `liveOverlay`.** It now starts or replaces the live overlay by selecting a region, with Space available to pick a window. An old `toggleOverlay` entry is ignored. Re-add the binding under `liveOverlay` or in Settings → Shortcuts.
- **`[overlay] enabled` is removed.** The overlay no longer has a persistent on/off. You place it by selecting a region/window and close it with the overlay's **×** button. The key is ignored if present.

### What's New

- **Pick a window like the macOS screenshot tool.** While selecting a region, press **Space** to switch to window mode. The window under the cursor highlights, and a click selects it. Region capture grabs that window independently of occlusion, while the live overlay snaps exactly onto it.
- **Drag-to-select live overlay.** Starting a live overlay now works just like a region capture: trigger **Live overlay…** (menu bar or shortcut), drag a region (or Space to pick a window), and an overlay snaps onto your selection and starts translating live immediately. No more "enable the overlay, position the floating panel, then turn on Live."
- **Built-in overlay controls.** The overlay carries an always-visible **LIVE** handle, coloured while live and monochrome when paused, plus an **×** button to close it.

### Changed

- **The overlay is always click-through.** Clicks and scrolling pass through to the apps below. Use the LIVE handle to move the overlay and its edges to resize it. The overlay now exists only while a live session is placed, with no persistent panel or idle guide.
- **Reworked the shortcut recorder.** A new recorder field (matching the app's Liquid Glass) shows shortcuts with stable English glyphs (e.g. `⌘S`) regardless of the active keyboard layout, records on a single click, flags a combo that's already in use, and clears with a dedicated button. The capture-window Save/Copy keys now live in `config.toml`'s `[shortcuts]` table (with `⌘S`/`⌘C`/`⌘O`/`⌘T` defaults) instead of being stored separately. Global hotkeys are now registered with **Magnet**.

## 2.5.0 (2026-06-09)

### What's New

- **Window live mode.** Live translation can now show in a separate, live-updating window while the overlay stays a thin region frame, so the source app underneath stays visible and usable. Switch between **In-place** and **Window** in the popover, Settings → Overlay, or with the new "Toggle live mode" shortcut.
- **Pass-through is automatic.** Once a translation is on screen, clicks and scrolling pass through to the app underneath while the edges still resize and the badge still drags. Only the idle guide stays interactive.

### Changed

- **Redesigned menu bar popover.** A compact control panel contains Capture Region, an Overlay section for visibility, Live, and display mode, plus a slim footer. The old Recognized and Translated text panels are gone.
- **Refreshed idle overlay guide.** The guide now uses a cleaner, centered card.

### Fixed

- The "Check for Updates" buttons could stay disabled. Updater availability now stays current.

## 2.4.1 (2026-06-02)

### Fixed

- **Stable `config.toml` ordering.** The config file's sections and keys were written in a non-deterministic order, churning the file on every change. Keys are now written sorted, so edits produce clean, minimal diffs.

## 2.4.0 (2026-06-02)

### What's New

- **Auto source language, now the default.** SwiftyCrow detects the source instead of requiring a manual choice. Detection runs per line on mixed-language screens, with a whole-capture fallback for short or ambiguous lines. Lines already in the target language stay unchanged.

## 2.3.0 (2026-06-01)

### What's New

- **Pass-through mode.** A new toggle and global shortcut let the overlay forward clicks, scrolling, and dragging to the apps below while the translation stays on top. The edges still resize it, the top-right badge still moves it, and an accent border with a PASS-THROUGH badge shows when enabled.

### Changed

- **The idle guide shows once per enable.** It appears when the overlay turns on, then stays out of the way. Toggling Live leaves a transparent frame instead of bringing the guide back.

### Fixed

- **Multi-monitor region capture.** The selector now opens on the screen under the cursor, so the selection and capture target the display you're actually pointing at instead of spanning all of them.

## 2.2.2 (2026-05-29)

### Performance

- **Region capture no longer stalls while blurring.** The blurred backdrop is now built with thread-safe Core Graphics / Core Image off the main thread, so the result window stays responsive while the gaussian blur and per-box compositing run.
- **Faster translation.** All lines are translated in a single on-device translation session (batched) instead of spinning up one session per line. Results still stream in progressively, chip by chip.
- Fixed a case where the translating spinner could stay spinning if a translation errored.

## 2.2.1 (2026-05-28)

### Fixed

- **Saved/copied capture images are now at the original screenshot's resolution.** Previously the screen-capture path was bounded by the on-screen window size, so tall captures the window had to shrink were saved at lower resolution. The window now briefly resizes to 1:1 with source pixels for save/copy, then restores.

## 2.2.0 (2026-05-28)

### Highlights

- **Region capture now matches the live overlay.** Translation chips render as the same Liquid Glass over a blurred backdrop. Save and copy use the on-screen result so the image you keep matches what you saw.
- **Smarter sentence stitching.** OCR lines that are part of one wrapped sentence are merged before translation (trimmed, language-aware joining, no more chopped per-line boxes).
- **Launch at Login.** A new *General* tab in Settings registers SwiftyCrow as a login item via `SMAppService`.
- **About tab.** Version, author, GitHub link, and open-source credits.
- **Sparkle update notes.** The update prompt now links to each release's notes on GitHub.

### Docs

- **Configuration reference moved out of the README.** [`docs/CONFIGURATION.md`](https://github.com/PangMo5/SwiftyCrow/blob/main/docs/CONFIGURATION.md) now keeps every key, default, and the shortcut syntax in one place.

## 2.1.0 (2026-05-27)

### What's New

- **Region capture.** Drag to select any area of the screen. It is OCR'd and translated, then shown in a borderless preview window with each line's box **blurred** and the translation drawn on top. `⌘S` saves a PNG (timestamped), `⌘C` copies the image, `⌘O`/`⌘T` copy the original/translated text, and `Esc` closes.
- **Customizable shortcuts.** Configure Capture Region / Toggle Live / Toggle Overlay (global) plus the result-window Save/Copy keys in **Settings → Shortcuts**.
- **Sectioned config.** `config.toml` is now grouped into `[capture]`, `[languages]`, `[overlay]`, `[recognition]`, `[shortcuts]`, `[translation]`, `[updates]`, mirroring the Settings tabs. Window geometry moved out of config into Application Support.
- **Explicit source language.** The "Auto" source option was removed. Pick the language that matches the text (defaults to English).

## 2.0.0 (2026-05-27)

### Highlights

- **In-place per-line translation.** Each recognized line is replaced by its translation on top of the source, sized to the original line height (Apple Translate camera mode style).
- **Floating glass overlay.** A transparent, borderless panel you can drag, resize, and auto-hide on hover. `⌘C` copies the current translation.
- **Live mode.** Re-captures the overlay region on an interval, with a pulsing `LIVE` badge while running.
- **Menu bar agent.** There is no Dock icon. Global shortcuts (Capture Once, Toggle Live, Toggle Overlay) work even with no window open.
- **Auto source detection** via Vision and a **dynamic language list** from the installed Apple Translation + OCR languages. Nothing is hardcoded.
- **Per-line translation cache** so repeat captures of the same screen skip the translation call.
- **Single TOML config** at `$XDG_CONFIG_HOME/SwiftyCrow/config.toml`, two-way synced with the in-app Settings.

### Under the hood

- 100% on-device: ScreenCaptureKit + Vision OCR + Apple Translation.
- Built for **macOS 26+** with the modern `SCScreenshotManager`, `RecognizeTextRequest`, and direct `TranslationSession` APIs.
- Sparkle-powered automatic updates.
