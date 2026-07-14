# Installing and Managing Translation Language Models

SwiftyCrow translates text using Apple's on-device translation framework, which requires translation models to be installed on your Mac. This guide walks you through installing, checking, and managing language models.

## Quick Start

If translation is failing with "Unable to translate":

1. Open **System Settings** on your Mac
2. Go to **General** → **Language & Region**
3. Scroll to **Translation Languages…** near the bottom
4. Click **Download** next to any language you want to translate
5. Wait for the download to complete (1–5 minutes per language)
6. Relaunch SwiftyCrow and try translating again

## Understanding Translation Models

- **What are they?** Language models are software files that teach your Mac how to translate text. Each language pair (e.g., English → Spanish) requires models to be installed.
- **Where do they live?** On your Mac's disk, managed by macOS. They stay on your computer — translation happens fully offline, no cloud services.
- **How much space?** Each language model is 1–3 GB. The total depends on how many languages you install.
- **Do I need both source and target?** Yes. If you translate English text to Spanish, you need both English and Spanish models installed.

## Step-by-Step Installation

### Via System Settings (Recommended)

1. Click the Apple menu (top-left corner) → **System Settings**
2. In the sidebar, click **General**, then **Language & Region**
3. Scroll down to find **Translation Languages…**
4. You'll see a list of languages with status badges:
   - **Download** (blue button) — model not installed; click to download
   - **Remove** (blue button) — model installed; click to delete it if you need disk space
   - **Downloading...** (gray) — download in progress; wait for it to finish
5. For each language you want, click **Download**
6. Wait for all downloads to finish (your Mac may show a progress indicator in System Settings)
7. Close System Settings and relaunch SwiftyCrow

### Verify Installation

To confirm a language model is installed:

1. Return to System Settings → General → Language & Region → Translation Languages…
2. If the button shows **Remove** instead of **Download**, the model is installed
3. That language is ready to use in SwiftyCrow

## Choosing Which Languages to Install

**For static source language (you know what language you're translating):**
- Install your source language (e.g., English)
- Install your target language (e.g., Spanish, French, German, etc.)

**For Auto source detection:**
- If SwiftyCrow is set to **Auto** source language in Settings, you don't know ahead of time what language your captures will contain
- Install models for every language that might appear in your screenshots
- This ensures translation works for any content you capture

**Common language pairs:**
- English → Spanish, French, German, Chinese, Japanese
- Supported on macOS 26+ (the language list changes by macOS version)

## Troubleshooting

### "Unable to translate" error appears

**Problem:** SwiftyCrow detected a language but the model isn't installed.

**Solution:**
1. Check which language SwiftyCrow detected: the error message should mention it
2. Go to System Settings → General → Language & Region → Translation Languages…
3. Look for that language and click **Download**
4. Once complete, try translating again in SwiftyCrow

### Translation works for some languages but not others

**Problem:** You've installed some models but not all the ones you need.

**Solution:**
- Check your source and target languages in SwiftyCrow Settings (`⌘,`)
- Go to System Settings and install models for both languages
- If using **Auto** source, install models for all languages that might appear in your captures

### "Translation framework unavailable"

**Problem:** Your Mac doesn't support Apple's translation framework.

**Solution:** SwiftyCrow requires macOS 26+. Check your system version:
1. Click the Apple menu → **About This Mac**
2. Look for "macOS" version — it should be 26 or higher
3. If you're on an older version, you'll need to update macOS or use a different translation tool

### Out of disk space after installing models

**Problem:** Language models take up 1–3 GB each; multiple languages can use a lot of space.

**Solution:**
1. Go to System Settings → General → Language & Region → Translation Languages…
2. Click **Remove** next to languages you don't actively use
3. This frees up disk space without affecting any other part of your Mac
4. You can always download them again later

### Slow translation, or Low Latency vs. High Fidelity

SwiftyCrow has a **Strategy** setting in Settings → Translation:
- **Low Latency** (default) — faster, uses fewer resources; good for casual reading
- **High Fidelity** — more accurate; uses Apple Intelligence on devices that support it (macOS 26.4+)

> **The Strategy setting only takes effect on macOS 26.4+.** On macOS 26.0–26.3 SwiftyCrow uses the Translation framework's own default and the choice has no effect, so switching modes there won't change speed or accuracy.

If translation feels slow:
1. On macOS 26.4+, try **Low Latency** mode (Settings → Translation)
2. Ensure your Mac isn't under heavy load (too many apps open)
3. For long captures, translation may take a few seconds regardless of strategy

## Feedback

If you encounter issues installing language models or translation still fails:
1. Check the [SwiftyCrow Issues](https://github.com/PangMo5/SwiftyCrow/issues) on GitHub
2. Include your macOS version, language pair, and the exact error message from SwiftyCrow
3. Note whether the language model was fully downloaded before attempting translation
