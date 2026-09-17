# SwiftyCrow Localization and UX Writing

English-only guidance for agents and contributors. This is not a localized user guide.

SwiftyCrow keeps one product model across languages, but it does not translate
English word for word. Each locale should make the next action obvious while
preserving the app's core concepts: a capture is a snapshot of a selected area,
live translation follows changes in that area, and the translated text remains
distinct from the original source text.

## Supported locales

| Locale | Audience | Writing model |
| --- | --- | --- |
| `en` | Global English | Apple-style clear, action-oriented writing: lead with the outcome, prefer familiar words, and reveal implementation detail only when it helps the next action |
| `ko` | Korea | Toss-style plain language: one message at a time, remove filler, explain the benefit before implementation details |
| `ja` | Japan | LINE and SmartHR-style clarity: use conversational Japanese, reduce reading effort, and make errors explain the next action without blaming the user |
| `zh-Hans` | Mainland China | Ant Design-style user-centered copy: put important information first, state the result and next action, and avoid commands or internal terminology |
| `zh-Hant` | Taiwan | Taiwan-centered, task-oriented writing with familiar `App`/`顯示器`/`設定`/`快速鍵` terminology |

`zh-Hant` currently targets Taiwan usage. Do not mix Hong Kong vocabulary into
this locale. Add `zh-HK` separately if SwiftyCrow supports Hong Kong later.

## SwiftyCrow voice

- Lead with the outcome: “Read the translation over the original.”
- Use one idea per sentence. Put prerequisites in a separate sentence.
- Name the user's object, not SwiftyCrow's internal subsystem.
- Use direct actions for buttons: “Capture Region”, “Open System Settings”.
- Explain destructive results before the user confirms them.
- Do not hide an error behind a friendly euphemism. Say what failed and what
  the user can do next.
- Keep paths, commands, keyboard glyphs, app names, and user-entered names and captured text unchanged.

## Core terminology

| Concept | `en` | `ko` | `ja` | `zh-Hans` | `zh-Hant` |
| --- | --- | --- | --- | --- | --- |
| Capture | Capture | 캡처 | キャプチャ | 截图 | 擷取 |
| Capture Region | Capture Region | 영역 캡처 | 範囲をキャプチャ | 截取区域 | 擷取區域 |
| Live translation | Live Translation | 실시간 번역 | ライブ翻訳 | 实时翻译 | 即時翻譯 |
| Original text | Original Text | 원문 | 原文 | 原文 | 原文 |
| Translated text | Translation | 번역문 | 訳文 | 译文 | 譯文 |
| In-place display | Over the Original | 원문 위에 표시 | 原文に重ねて表示 | 在原文上显示 | 顯示在原文上 |
| Separate window | Separate Window | 별도 창 | 別のウインドウ | 独立窗口 | 獨立視窗 |
| Fit image | Fit Image | 창에 맞추기 | ウインドウに合わせる | 适合窗口 | 配合視窗 |
| Language model | Language Model | 언어 모델 | 言語モデル | 语言模型 | 語言模型 |
| Source language | Source Language | 원문 언어 | 原文の言語 | 源语言 | 原文語言 |
| Target language | Translation Language | 번역 언어 | 翻訳先の言語 | 目标语言 | 翻譯語言 |
| Settings | Settings | 설정 | 設定 | 设置 | 設定 |
| Keyboard shortcut | Shortcut | 단축키 | ショートカット | 快捷键 | 快速鍵 |

Use these terms consistently. A locale may rewrite an entire sentence around
the term; it must not silently change the underlying behavior.

In Korean, keep product and platform names such as `SwiftyCrow` and `Apple
Intelligence` unchanged. Write functional concepts in understandable Korean:
영역 캡처, 실시간 번역, 원문, 번역문, and 창에 맞추기. Describe what users can do
rather than exposing internal OCR or rendering terminology in everyday controls.

### English voice

- Follow Apple writing guidance: make copy clear, concise, useful, and
  action-oriented. Put the result or benefit before instructions.
- Prefer the user's visible object and action: `Live Translation`, `Over the
  Original`, and `Separate Window` describe the result instead of internal
  capture, rendering, or window-management mechanisms.
- Buttons and menu commands start with a verb. Settings labels describe what
  happens when the setting is on.
- Empty states name what is missing and, when useful, follow with one next
  action. Errors say what failed, what remains safe, and how to recover.
- Keep `BSP`, `TOML`, and file names only where the implementation itself is
  being inspected or configured.

### Korean voice

- Use 해요체 for titles, empty states, descriptions, confirmations, and
  errors. Keep buttons, picker values, and section headings as short action or
  noun labels when a full sentence would slow scanning.
- Describe the user's action, not a system state: `선택된 항목 없음` becomes
  `선택한 항목이 없어요`, and `추가됨` becomes `추가했어요`.
- Follow a problem with the next useful action when one exists. Do not repeat
  the title in the body.
- Prefer everyday outcomes over implementation terms: use `화면 알림` instead
  of `HUD` or `오버레이`, but keep necessary domain terms such as `BSP`,
  `TOML`, and keyboard key names.
- Never attach a variable Korean postposition to a user-entered name. Rewrite
  `“%@”을 삭제할까요?` as `삭제할까요? · “%@”`.

### Japanese voice

- Use familiar spoken Japanese without overusing polite filler. Descriptions
  use complete `です／ます` sentences; buttons and menu commands use short
  actions.
- Prefer familiar macOS wording such as `キャプチャ`, `ウインドウ`, `原文`,
  and `翻訳` over stiff translations or unexplained internal terminology.
- Empty states are complete statements such as `項目が選択されていません`.
  Errors explain the problem and the next useful action without blaming the
  user.

### Simplified Chinese voice

- Put the outcome before the operation. Use short, complete wording and make
  the next action explicit when something fails.
- Use `应用`, `截图`, `实时翻译`, `窗口`, and `快捷键` consistently.
  Do not mix English `App` into Mainland Chinese UI copy.
- Keep labels free of unnecessary punctuation. Use punctuation for complete
  sentences and multi-step guidance.

### Traditional Chinese voice

- Target Taiwan usage. Use `App`, `擷取`, `即時翻譯`, `顯示器`,
  `快速鍵`, `設定`, and `視窗`.
- Prefer task language and visible outcomes over literal technical
  translations. Use `點按`, `檔案`, `游標`, and `螢幕` in their familiar
  macOS contexts.
- Keep Hong Kong-specific vocabulary out of `zh-Hant`; add `zh-HK` as a
  separate locale if needed.

## Implementation rules

- Put app UI strings in `Resources/Localizable.xcstrings` and permission text
  in `Resources/InfoPlist.xcstrings`. The app owns both runtime catalogs.
- Use `swift run --package-path Tools swiftycrow-tools` to collect, validate, and generate localized
  documentation and websites. The catalogs are the source of truth; do not edit
  generated locale files by hand.
- Keep extracted English source keys stable. Store reviewed displayed English
  as explicit `en` localizations in the catalog, so UX copy can improve without
  renaming every Swift lookup key.
- Use `LocalizedStringResource` for fixed UI copy passed between models,
  helpers, and views. Keep user-entered names and discovered app/display names
  as `String`.
- Pass string literals directly to SwiftUI controls.
- Use `String(localized:)` only when a concrete `String` is required outside a
  SwiftUI initializer.
- Interpolate a complete sentence. Never concatenate translated fragments.
- Preserve format placeholders and let each locale reorder them.
- Use locale-aware `FormatStyle` for user-visible numbers and dates.
- Do not uppercase localized copy at runtime.
- Do not use em dashes in interface copy. Split the thought into sentences or
  use punctuation that fits the locale.

## Documentation, website and demo films

The same terminology and writing rules apply outside the app.

- Keep English user-facing documentation as the source, with localized README
  and guide files generated from `Localization/Docs.json`. Preserve commands,
  code samples, identifiers, link destinations and explicit heading anchors.
- Keep internal Demo Lab documentation (`DemoLab/README.md` and `DemoLab/docs/`)
  in English only. Exclude it from document translation and language navigation.
  This does not change localization of fixture UI, film captions, or review
  gallery controls.
- `Localization/Web.json` contains complete website text units. Each locale
  has its own URL and document language, including navigation, accessible
  labels, loading/error states, documentation and demo gallery controls.
- Independent demo fixture apps, when used, own a separate
  `DemoLab/Localization/Localizable.xcstrings` catalog in their main bundle.
  Shared helpers pass `LocalizedStringResource`; saved fixture data resolves
  complete strings in the language selected for that recording. Captured sample
  text stays in its declared source language, independently of the app UI locale.
- Film captions, titles and human input share `DemoLab/Localization/Films.json`.
  Generate input assertions from those same values. Prefer stable accessibility
  identifiers over translated labels, which may legitimately be identical.
- Record and validate each app language. Translated subtitles over English UI
  do not establish that a localized app was exercised.
- Inspect appearance, scrolling, zoom, resizing, and dismissal transitions in
  the camera original. Reject black remnants, magenta surfaces, or other graphics
  corruption even when decoding, OCR, frame counts, and action assertions pass.
  Compare separate guest screenshots and preserve failure timestamps and logs.
- Target the owned Tart VM by exact name. Never stop all Tart processes or use
  the first running guest. Do not crop corruption out or disable product effects
  to make a take pass.
- Reject missing translations and changed placeholders at build time. A
  translation must not quietly fall back to English to make a build pass.
- Keep the authoritative English release history unchanged while maintaining
  localized copies. Preserve license/copyright texts verbatim; localize the
  explanatory overview and link clearly to the original notices.
- Bundle the existing document sources for every supported app language.
  Repository language navigation must not appear inside the app.

## Review checklist

1. Build with `SWIFT_EMIT_LOC_STRINGS=YES`, then sync compiler-generated
   `.stringsdata` into the catalog.
2. Verify every supported locale has a translation for every translatable key.
3. Verify each translation preserves the source placeholder set.
4. Launch once per locale with the scheme's Application Language override.
5. Check Settings, menu bar, destructive confirmations, empty states, and capture previews, overlays,
   information popovers, and language-model guidance for clipping and mixed-language text.
6. Have a native reviewer check tone and terminology before release. SwiftyCrow's
   catalog is written from screen context; do not seed it with machine
   translation.

## Public references

- Toss: <https://toss.tech/article/21022>
- Apple Human Interface Guidelines: Writing:
  <https://developer.apple.com/design/human-interface-guidelines/writing>
- Apple WWDC25: Make a big impact with small writing changes:
  <https://developer.apple.com/videos/play/wwdc2025/404/>
- LINE Voice: <https://designsystem.line.me/about/line-voice-ja>
- SmartHR writing style:
  <https://smarthr.design/products/contents/writing-style/>
- SmartHR UI text:
  <https://smarthr.design/products/contents/ui-text/app-writing/>
- SmartHR error messages:
  <https://smarthr.design/products/contents/error-messages/overview/>
- Ant Design copywriting:
  <https://ant.design/docs/spec/copywriting-cn/>
- Taiwan government web content guidelines:
  <https://www.webguide.nat.gov.tw/guidelines/442/show>
