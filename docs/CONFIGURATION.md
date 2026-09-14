<!-- LANGUAGE-LINKS:START -->
[English](CONFIGURATION.md) · [한국어](ko/CONFIGURATION.md) · [日本語](ja/CONFIGURATION.md) · [简体中文](zh-Hans/CONFIGURATION.md) · [繁體中文](zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

# Configuration

This reference follows `main`. For a released version, read this file in its matching [release tag](https://github.com/PangMo5/SwiftyCrow/tags).

SwiftyCrow reads its configuration from:

```
~/.config/SwiftyCrow/config.toml
```

The path is XDG-aware. If `$XDG_CONFIG_HOME` is set, the file lives at
`$XDG_CONFIG_HOME/SwiftyCrow/config.toml`. The file is created on first launch
and written back whenever you change something in the app. Changes made in your editor are also picked up while the app is running.

Settings are grouped into tables that mirror the in-app Settings panes:

- **`[languages]`:** Source and target language pair
- **`[overlay]`:** Live translation overlay
- **`[shortcuts]`:** Global hotkeys and capture-window keys
- **`[translation]`:** Translation strategy
- **`[updates]`:** Automatic update checks

One thing is intentionally **not** in this file:

- Overlay window position/size is UI state, saved to
  `~/Library/Application Support/SwiftyCrow/overlay-frame.json`.

## Shortcut syntax

Global shortcuts use an skhd-style string: zero or more modifiers joined by
`+`, then ` - `, then the key.

```
cmd + shift - c
ctrl + alt - space
cmd + ctrl + shift + alt - z
```

Modifiers: `cmd`, `ctrl`, `alt` (option), `shift`. Keys are letters, digits,
`tab`, `return`, `space`, arrow keys (`left`/`right`/`up`/`down`), punctuation,
etc. Omit a key to leave that action unbound.

Live capture adapts automatically: it checks frequently while content changes
and slows down when the screen is still. OCR runs only for changed pixels or
language settings. Scrolling refreshes as soon as the gesture settles.
The former `[capture].interval` setting is ignored and omitted on the next save.

## `[languages]`

A nested table per side, each holding a BCP-47 language `code`. The lists
available in the app are supported by macOS; source languages must also support OCR. Models for your chosen pair need to be downloaded separately.

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `source.code` | string | `"auto"` | Language to translate **from**. Defaults to `"auto"`, which detects it per line from the captured text. Set a specific code (e.g. `"en-US"`) to pin it. |
| `target.code` | string | system | Language to translate **to**. Defaults to your system's preferred language. |

## `[overlay]`

Click **Live translation** in the menu bar or use the `liveOverlay` shortcut to select a region or window. Clicking the button again chooses a new area. The translation area lets clicks pass through to the app below; controls, resize edges, and an open information popover receive input. Use **LIVE** to pause or resume and **×** to close it.

The `toggleLiveOverlay` shortcut and the **Show overlay** switch show or hide translation in the selected area. Turning it off stops capture and translation. Turning it back on uses the remembered area. The switch is disabled until an area has been selected; the shortcut does nothing without a saved area.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `hideOnHover` | bool | `false` | Fade the overlay out while the cursor is over it, so the original text underneath is readable. |
| `liveMode` | string | `"inPlace"` | How a live translation is shown: `inPlace` draws it over the text, `window` keeps the overlay a thin region frame and shows the translation in a separate window. |

## `[shortcuts]`

All values are skhd-style shortcut strings (see above). Omit a global key to
leave that action unbound (the default).

**Global hotkeys:** Fire even when the app is in the background.

| Key | Action |
| --- | --- |
| `selectRegion` | Capture a region. Drag to select, or press Space to pick a window. |
| `liveOverlay` | Start or replace the live overlay using the same selection, then translate live. |
| `toggleLiveOverlay` | Show or hide the live overlay on the **last-used region** without another selection. Hiding it stops capture and translation. Showing it restores the remembered region and goes live. |
| `toggleLive` | Pause/resume Live on the active overlay (keeps it on screen) |
| `toggleLiveMode` | Switch the live display between In-place and Window |

**Capture-window keys:** Active only while a capture result window is focused.
they have ⌘ defaults:

| Key | Action | Default |
| --- | --- | --- |
| `regionSave` | Save the image | `cmd - s` |
| `regionCopyImage` | Copy the image | `cmd - c` |
| `regionCopyOriginal` | Copy the original text | `cmd - o` |
| `regionCopyTranslation` | Copy the translation | `cmd - t` |

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
liveOverlay = "cmd + shift - o"
toggleLiveOverlay = "cmd + shift - k"
toggleLive = "cmd + shift - l"
toggleLiveMode = "cmd + shift - m"
```

> **Renamed in 2.6.0:** the `toggleOverlay` key is now `liveOverlay`. An old
> `toggleOverlay` entry is ignored. Re-add the binding under `liveOverlay`.

## `[translation]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `strategy` | string | `"lowLatency"` | Preferred local strategy: `lowLatency` or `highFidelity` (macOS 26.4+). SwiftyCrow uses this strategy when its model is installed, otherwise an installed alternative and displays a notice. |

## `[updates]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `automaticChecks` | bool | `true` | Periodically check for new releases in the background. |
| `checkInterval` | string | `"daily"` | How often to check: `hourly`, `daily`, or `weekly`. |
