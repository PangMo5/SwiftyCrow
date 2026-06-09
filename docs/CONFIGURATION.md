# Configuration

SwiftyCrow reads its configuration from:

```
~/.config/SwiftyCrow/config.toml
```

The path is XDG-aware — if `$XDG_CONFIG_HOME` is set, the file lives at
`$XDG_CONFIG_HOME/SwiftyCrow/config.toml`. The file is created on first launch
and written back whenever you change something in the app. Hand edits are
picked up on the next launch, so you can keep it in your dotfiles and edit it
in your editor.

Settings are grouped into tables that mirror the in-app Settings tabs:

- `[capture]` — Live Mode capture cadence
- `[languages]` — source/target language pair
- `[overlay]` — the live translation overlay
- `[recognition]` — OCR mode
- `[shortcuts]` — global hotkeys
- `[translation]` — translation strategy
- `[updates]` — automatic update checks

Two things are intentionally **not** in this file:

- Overlay window position/size is UI state, saved to
  `~/Library/Application Support/SwiftyCrow/overlay-frame.json`.
- The capture-window Save/Copy keys are stored by macOS (set them in
  Settings → Shortcuts).

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

## `[capture]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `interval` | double | `0.8` | Seconds between re-captures while Live Mode is on. |

## `[languages]`

A nested table per side, each holding a BCP-47 language `code`. The lists
available in the app are the languages installed on your Mac.

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `source.code` | string | `"auto"` | Language to translate **from**. Defaults to `"auto"`, which detects it per line from the captured text; set a specific code (e.g. `"en-US"`) to pin it. |
| `target.code` | string | system | Language to translate **to**; defaults to your system's preferred language. |

## `[overlay]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Show the live translation overlay window. |
| `hideOnHover` | bool | `false` | Temporarily hide the overlay while the cursor is over it. |
| `liveMode` | string | `"inPlace"` | How a live translation is shown: `inPlace` draws it over the text, `window` keeps the overlay a thin region frame and shows the translation in a separate window. Once a translation is on screen, clicks/scroll pass through to the apps below. |

## `[recognition]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `mode` | string | `"text"` | OCR mode: `text`, or `document` to group lines into paragraphs (macOS 26+). |

## `[shortcuts]`

All values are skhd-style shortcut strings (see above). These hotkeys are
global — they fire even when the app is in the background. Omit a key to leave
that action unbound (the default).

| Key | Action |
| --- | --- |
| `selectRegion` | Start a region capture |
| `toggleLive` | Toggle Live Mode on the overlay |
| `toggleOverlay` | Show/hide the overlay window |
| `toggleLiveMode` | Switch the live mode between In-place and Window |

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
toggleLive = "cmd + shift - l"
toggleOverlay = "cmd + shift - o"
toggleLiveMode = "cmd + shift - m"
```

## `[translation]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `strategy` | string | `"lowLatency"` | `lowLatency`, or `highFidelity` to use Apple Intelligence where supported (macOS 26.4+). |

## `[updates]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `automaticChecks` | bool | `true` | Periodically check for new releases in the background. |
| `checkInterval` | string | `"daily"` | How often to check: `hourly`, `daily`, or `weekly`. |
