---
title: "fix: Resolve 'Unable to translate' error in translation feature"
created: 2026-06-13
origin: "GitHub issue #6"
type: "fix"
depth: "standard"
---

## Problem Frame

Users report that the translation feature consistently fails with the error message "Unable to translate" in version 2.6.1. Investigation reveals the error originates from Apple's Translation framework, indicating that the source language detected from the captured text does not have a translation model installed on the device. The error occurs in the live overlay but is silently swallowed in region capture, creating inconsistent UX.

## Requirements

- **R1.** Translation feature must gracefully handle missing language models instead of showing a cryptic framework error
- **R2.** User must receive clear feedback about why translation failed (e.g., "Translation models for [language] are not installed")
- **R3.** Live overlay and region capture must have consistent error reporting behavior
- **R4.** App should provide a path for users to resolve the issue (install missing models or switch languages)

## Success Criteria

- "Unable to translate" error no longer shown; replaced with clear, actionable message
- Both live overlay and region capture report translation errors consistently
- Error message includes which language failed and suggests user action
- No regressions in translation performance or feature behavior

---

## High-Level Technical Design

```
User attempts translation
  ↓
Capture & OCR
  ↓
Language detection per line
  ↓
Group lines by detected source language
  ↓
For each group, create TranslationSession(installedSource: detectedLanguage, ...)
  ├─ If detectedLanguage model is not installed:
  │  → Translation framework throws error
  │  → NEW: Catch, identify missing language
  │  → Provide actionable error message
  │
  └─ If detectedLanguage model is installed:
     → Translate batch
     → Stream results to UI

Error Flow (NEW):
  Translation error
    → Identify root cause (missing model vs. other)
    → Format user-friendly message
    → Pass to both CaptureFeature and RegionCaptureFeature
    → Display in UI (live overlay or result window)
```

---

## Scope Boundaries

### In Scope
- Diagnosing why TranslationSession fails (missing language models)
- Capturing and categorizing translation errors
- Displaying actionable error messages to users
- Making region capture error handling consistent with live overlay
- Testing the fix with multiple language scenarios

### Out of Scope
- Automatic model installation or download (OS-level responsibility)
- Adding fallback translation services (stay with Apple's Translation framework)
- Full translation feature refactor or architecture changes
- Support for languages beyond what macOS 26+ provides

### Deferred for Follow-Up
- Add comprehensive unit test suite for all translation scenarios
- Implement user preference for fallback language when primary isn't available
- Localize error messages for non-English users

---

## Key Technical Decisions

**KTD.1 — Error Categorization Strategy**
Distinguish between "missing translation model" and "other translation errors" at the point of failure. Map the framework error's `localizedDescription` and error type to a structured error enum in the app rather than passing through raw framework errors.

*Rationale:* The "Unable to translate" error is Apple's generic message. By categorizing at the TranslationClient level, both capture paths (live and region) can handle errors consistently and provide context-specific messages to the user.

**KTD.2 — Consistent Error Reporting in Both Capture Paths**
Unify error handling so that region capture reports translation errors to the UI instead of silently swallowing them. Add a `lastError` state to RegionCaptureFeature's reducer, just as CaptureFeature has.

*Rationale:* Currently, users performing region capture get no feedback if translation fails — they see source text and assume the feature worked. This is confusing and inconsistent with the live overlay behavior. Making both paths report errors improves debuggability and user experience.

**KTD.3 — Error Message Content**
Include the detected source language name and a suggestion to check Settings or manually select a source language if auto-detection is unreliable.

*Rationale:* Users need to know which language is missing so they can either switch to a language that is installed or understand that they need to change their source text. Surfacing the detected language is essential for troubleshooting.

---

## Implementation Units

### U1. Create Structured Translation Error Type

**Goal**
Define a new error enum that categorizes translation framework errors into actionable types: missing language model, translation service unavailable, unsupported language pair, and generic errors. This allows both capture paths to handle and display errors consistently.

**Requirements**
- R1, R2 (foundation for error messaging)

**Dependencies**
- None

**Files**
- `Sources/Models/TranslationError.swift` (new)

**Approach**
Create a `TranslationError` enum with cases:
- `missingLanguageModel(language: String)` — the source language's translation model is not installed
- `unsupportedLanguagePair(source: String, target: String)` — the language pair is not supported by the framework
- `frameworkUnavailable` — Translation framework is unavailable (e.g., macOS < 26)
- `unknown(String)` — catch-all for unexpected errors

Add a computed property `userFacingMessage` that generates clear, actionable text for each case.

Implement `Equatable` and `Codable` for testing and potential logging.

**Patterns to Follow**
- Follow the app's existing error enum patterns (e.g., OCRError in OCRClient if present)
- Use localized strings for user-facing messages (set up for future localization)

**Test Scenarios**
- Test each error case produces the correct user-facing message
- Test that "missing model for German" produces a message naming "German" and suggesting action
- Test that unknown errors fall back to a generic message without crashing

**Verification**
- Error type is serializable and can be passed through TCA actions
- User-facing message is clear and actionable without technical jargon

---

### U2. Update TranslationClient to Catch and Categorize Errors

**Goal**
Modify TranslationClient to catch errors from Apple's Translation framework and map them to the new TranslationError enum. Provide context about which language failed.

**Requirements**
- R1 (capture errors), R2 (categorize them)

**Dependencies**
- U1

**Files**
- `Sources/Dependencies/TranslationClient.swift` (modify)

**Approach**
In the `translateBatch()` method:
1. Wrap the TranslationSession creation in a do-catch block
2. When TranslationSession throws, inspect the error to determine the cause
   - If it mentions a missing model, extract the language name and throw `TranslationError.missingLanguageModel(language)`
   - If it's an unsupported language pair, throw `TranslationError.unsupportedLanguagePair(...)`
   - If it's a framework unavailability, throw `TranslationError.frameworkUnavailable`
   - Otherwise, throw `TranslationError.unknown(error.localizedDescription)`
3. Propagate the `TranslationError` up the stream

Add a private helper method `categorizeFrameworkError(_:sourceLanguage:targetLanguage:)` to handle the mapping logic.

**Patterns to Follow**
- Keep the async stream pattern; just change what errors propagate
- Use the existing dependency injection pattern

**Test Scenarios**
- When TranslationSession creation fails with a missing-model error for a specific language, verify `TranslationError.missingLanguageModel` is thrown with that language name
- When an unsupported language pair is used, verify the correct error is thrown
- When an unknown error occurs, verify it's caught and wrapped in `TranslationError.unknown`

**Verification**
- TranslationClient properly categorizes framework errors
- Error contains enough information for the UI to display an actionable message

---

### U3. Update CaptureFeature (Live Overlay) to Handle Structured Errors

**Goal**
Modify the live overlay's error handling to work with the new TranslationError type and display the user-facing message properly.

**Requirements**
- R1, R2, R4 (display clear error)

**Dependencies**
- U1, U2

**Files**
- `Sources/Capture/CaptureFeature.swift` (modify)

**Approach**
In the translation error catch block (currently line 328–330):
1. Pattern match on the `TranslationError` to determine the error type
2. For `missingLanguageModel`, construct a message like: "Translation model for [language] is not installed. Check Settings to install language models or switch to a different language."
3. For other errors, use the `userFacingMessage` from the error enum
4. Pass the message to the `.translationFailed(message)` action as before

No structural changes needed; just improve the error message content.

**Patterns to Follow**
- Follow existing TCA action patterns in CaptureFeature
- Reuse the `lastError` state display mechanism

**Test Scenarios**
- When a missing-language-model error occurs, verify the UI displays a message naming the language
- When an unsupported-pair error occurs, verify a different message is shown
- Verify the error message is not truncated or mangled in the UI

**Verification**
- Live overlay displays actionable error messages instead of "Unable to translate"
- User can understand what went wrong and what to do next

---

### U4. Update RegionCaptureFeature (Region Capture) to Report Errors

**Goal**
Make region capture error handling consistent with live overlay by catching translation errors and displaying them in the UI instead of silently failing.

**Requirements**
- R3 (consistent error reporting), R2 (same messaging)

**Dependencies**
- U1, U2, U3

**Files**
- `Sources/Capture/RegionCaptureFeature.swift` (modify)

**Approach**
1. Add a `lastError: String?` state to RegionCaptureFeature's State struct (mirroring CaptureFeature)
2. Replace the silent catch block (line 138: `catch { }`) with proper error handling
3. On translation error, set `state.lastError = error.userFacingMessage`
4. Update `RegionResultView.swift` to display `lastError` as a red warning (similar to CaptureView)
5. Clear `lastError` when a new capture is initiated

**Patterns to Follow**
- Mirror the error state and display patterns from CaptureFeature
- Use the same error message formatting

**Test Scenarios**
- When region capture translation fails, verify `lastError` is populated with the user-facing message
- Verify the error is displayed in the region result window
- Verify that initiating a new capture clears the previous error
- Verify happy-path region capture (successful translation) does not display an error

**Verification**
- Region capture now surfaces translation errors instead of hiding them
- Both capture paths have consistent error UX

---

### U5. Add Tests for Translation Error Handling

**Goal**
Add unit and integration tests to verify that translation errors are caught, categorized, and displayed correctly to users.

**Requirements**
- R1–R4 (verify all requirements)

**Dependencies**
- U1, U2, U3, U4

**Files**
- `Tests/CaptureFeatureTests.swift` (new or modify)
- `Tests/RegionCaptureFeatureTests.swift` (new or modify)
- `Tests/TranslationClientTests.swift` (new or modify)

**Approach**
Create a test suite covering:

1. **TranslationClient tests:**
   - Mock Apple's TranslationSession to throw a missing-model error
   - Verify TranslationClient categorizes it as `TranslationError.missingLanguageModel`
   - Repeat for other error types

2. **CaptureFeature tests:**
   - Mock TranslationClient to throw a missing-language-model error
   - Send a translation request via the live capture loop
   - Verify CaptureFeature's state is updated with `.translationFailed(message)` action
   - Verify the message includes the language name and actionable text

3. **RegionCaptureFeature tests:**
   - Mock TranslationClient to throw a translation error
   - Perform a region capture
   - Verify `lastError` state is set with the user-facing message
   - Verify a subsequent capture clears the error

4. **Integration scenario:**
   - Capture a region with text in a language without an installed model
   - Verify the error is reported in the UI and includes actionable guidance

**Patterns to Follow**
- Use dependency injection to mock TranslationClient in tests
- Follow existing test patterns in the project (TCA Reducer testing)
- Use `@MainActor` where needed for SwiftUI view tests

**Test Scenarios**
- **Happy path:** Successful translation with installed model
- **Missing model error:** Language detected, model not installed, error reported
- **Unsupported pair error:** Valid source and target, but pair not supported by framework
- **Framework unavailable:** Translation framework errors out (e.g., on older OS)
- **Unknown error:** Framework throws an unexpected error; app handles gracefully
- **Consistency check:** Live overlay and region capture both report the same error message for the same failure

**Verification**
- All test scenarios pass
- Code coverage for translation error paths is ≥ 90%
- No regressions in happy-path translation

---

### U6. Add User Guidance for Installing Translation Language Models

**Goal**
Provide users with clear, in-app and in-documentation guidance on how to install translation language models on their Mac when they encounter a missing-language error.

**Requirements**
- R2 (guide user to resolution), R4 (provide path to resolve the issue)

**Dependencies**
- U1, U3, U4 (error messages that reference this guidance)

**Files**
- `README.md` (modify — add Troubleshooting section)
- `docs/LANGUAGE_MODELS.md` (new — detailed guide)
- `Sources/Capture/CaptureView.swift` (modify — add help link in error display)
- `Sources/Capture/RegionResultView.swift` (modify — add help link in error display)

**Approach**
1. **Update README.md:**
   - Add a new `## Troubleshooting` section
   - Include a subsection "Translation says 'Unable to translate' or language isn't supported"
   - Provide step-by-step instructions for macOS System Settings → Language & Region → Translation
   - List which languages require models and how to check installation status

2. **Create docs/LANGUAGE_MODELS.md:**
   - Detailed guide on installing and managing translation models on macOS
   - Screenshots of the Settings process
   - Tips for choosing between `.lowLatency` and `.highFidelity` strategies
   - Troubleshooting checklist

3. **Update error display in CaptureView and RegionResultView:**
   - When `lastError` contains "language model", append a link text like "(Learn how to install languages →)"
   - Link should open `docs/LANGUAGE_MODELS.md` or direct user to System Settings

**Patterns to Follow**
- Keep README concise; detailed docs go to `docs/`
- Use the existing error display styling

**Test Scenarios**
- User sees missing-language error; clicks help link and reaches installation instructions
- README Troubleshooting section clearly explains the issue and resolution
- `LANGUAGE_MODELS.md` is discoverable from GitHub and from in-app error messages

**Verification**
- Users encountering translation errors can find installation instructions within 2 clicks
- README and documentation are kept in sync with error messages

---

## Execution Note

Start with a **characterization test** for the current behavior: capture region capture's silent error handling and the live overlay's error message. Then implement U1–U4. The characterization test becomes the regression suite to verify the fix doesn't break existing happy-path behavior. U6 (documentation) can be completed in parallel once error messages are finalized.

---

## Sources & Research

- **Apple Vision framework docs:** RecognizeTextRequest (OCR)
- **Apple Translation framework docs:** TranslationSession API, available macOS 26+, language model installation requirements
- **Codebase analysis:** TranslationClient, CaptureFeature, RegionCaptureFeature implementations
- **Root cause:** Per-line language detection (added in v2.4.0) can resolve to languages whose translation models are not installed on the user's device
