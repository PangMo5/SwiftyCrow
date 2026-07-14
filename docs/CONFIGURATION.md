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

Settings are grouped into tables that mirror the in-app Settings panes:

- `[capture]` — Live Mode capture cadence
- `[languages]` — source/target language pair
- `[overlay]` — the live translation overlay
- `[shortcuts]` — global hotkeys + capture-window keys
- `[translation]` — translation strategy
- `[updates]` — automatic update checks

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

The overlay is no longer a persistent window you toggle on; you place it by
selecting a region or window (menu bar → **Live overlay…**, or the `liveOverlay`
shortcut), and it starts translating live right away. It always lets clicks pass
through to the apps below — use its built-in **LIVE** handle to pause/resume and
the **×** button to close it.

Once you've placed it, the region is remembered — the `toggleLiveOverlay`
shortcut (or menu bar → **Show on last region** / **Hide overlay**) flips the
overlay on and off over that same region without dragging again. Hiding it stops
all capture and translation; showing it re-places on the remembered region and
goes live. That's the "predefine an area, then translate it on demand" flow.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `hideOnHover` | bool | `false` | Fade the overlay out while the cursor is over it, so the original text underneath is readable. |
| `liveMode` | string | `"inPlace"` | How a live translation is shown: `inPlace` draws it over the text, `window` keeps the overlay a thin region frame and shows the translation in a separate window. |

## `[shortcuts]`

All values are skhd-style shortcut strings (see above). Omit a global key to
leave that action unbound (the default).

**Global hotkeys** — fire even when the app is in the background:

| Key | Action |
| --- | --- |
| `selectRegion` | Capture a region (drag to select; press Space to pick a window) |
| `liveOverlay` | Start/replace the live overlay (same selection; then translates live) |
| `toggleLiveOverlay` | Show/hide the live overlay on the **last-used region** — no re-selecting. Hiding it stops all capture/translation; showing it re-places on the remembered region and goes live. |
| `toggleLive` | Pause/resume Live on the active overlay (keeps it on screen) |
| `toggleLiveMode` | Switch the live display between In-place and Window |

**Capture-window keys** — active only while a capture result window is focused;
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
> `toggleOverlay` entry is ignored — re-add the binding under `liveOverlay`.

## `[translation]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `strategy` | string | `"lowLatency"` | `lowLatency`, or `highFidelity` to use Apple Intelligence where supported (macOS 26.4+). |

## `[updates]`

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `automaticChecks` | bool | `true` | Periodically check for new releases in the background. |
| `checkInterval` | string | `"daily"` | How often to check: `hourly`, `daily`, or `weekly`. |
