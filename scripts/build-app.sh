#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo/scripts/xcode-env.sh"
cd "$repo"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
xcode_version="$(xcodebuild -version | awk '/^Xcode / { print $2 }')"
xcode_build="$(xcodebuild -version | awk '/^Build version / { print $3 }')"
xcode_numeric="$(awk -F. '{ printf "%02d%d%d", $1, $2, $3 }' <<< "$xcode_version")"

configuration="${1:-debug}"
if [[ $# -gt 1 || ( "$configuration" != debug && "$configuration" != release ) ]]; then
  echo "Usage: build-app.sh [debug|release]" >&2
  exit 2
fi
if [[ -n "${SWIFTYCROW_REVIEW_LOCALE:-}" && "$configuration" != debug ]]; then
  echo "Locale review is supported only in Debug builds." >&2
  exit 1
fi
version="$(cat "$repo/VERSION")"
build_number="${SWIFTYCROW_BUILD_NUMBER:-1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[0-9]+$ ]]; then
  echo "VERSION must contain a semantic version; SWIFTYCROW_BUILD_NUMBER must be numeric." >&2
  exit 1
fi

if [[ "$configuration" == debug ]]; then
  display_configuration=Debug
  bundle_id=dev.PangMo5.SwiftyCrow.debug
  display_name="SwiftyCrow Dev"
  app_icon=AppIcon-Debug
  identity="${SWIFTYCROW_DEVELOPMENT_IDENTITY:-Apple Development}"
  architectures=("$(uname -m)")
else
  display_configuration=Release
  bundle_id=dev.PangMo5.SwiftyCrow
  display_name=SwiftyCrow
  app_icon=AppIcon
  identity="${SWIFTYCROW_DISTRIBUTION_IDENTITY:-Developer ID Application}"
  architectures=(arm64 x86_64)
fi

checks=(--root "$repo")
if [[ -n "${SWIFTYCROW_REVIEW_LOCALE:-}" ]]; then checks+=(--locale "$SWIFTYCROW_REVIEW_LOCALE"); fi
swift run --package-path "$repo/Tools" swiftycrow-tools check "${checks[@]}"
mkdir -p .build/localized-strings DerivedData
stage="$(mktemp -d "$repo/DerivedData/.app-build.XXXXXX")"
trap 'rm -r "$stage"' EXIT
app="$stage/SwiftyCrow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" "$stage/binaries"
launchers=()
# Build all architectures together so host macro tools and destination objects
# retain their distinct architectures. A versioned --triple would also override
# dependencies' own minimum OS versions, breaking back-deployment libraries.
options=(--configuration "$configuration" --sdk "$sdk_path")
for arch in "${architectures[@]}"; do options+=(--arch "$arch"); done
swift build --package-path "$repo" --product SwiftyCrow "${options[@]}"
products="$(swift build --package-path "$repo" --show-bin-path "${options[@]}")"
for arch in "${architectures[@]}"; do
  xcrun lipo "$products/libSwiftyCrow.dylib" -verify_arch "$arch"
done
module_maps="$repo/.build/out/Intermediates.noindex/GeneratedModuleMaps"
for arch in "${architectures[@]}"; do
  # The launcher only enters the SwiftPM module. SPM owns all app compilation.
  swiftc -parse-as-library -swift-version 5 -sdk "$sdk_path" -target "$arch-apple-macosx26.0" \
    -I "$products" -F "$products" -L "$products" -lSwiftyCrow \
    -Xcc "-fmodule-map-file=$module_maps/CTomlPlusPlus.modulemap" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$repo/App/main.swift" -o "$stage/binaries/SwiftyCrow-$arch"
  launchers+=("$stage/binaries/SwiftyCrow-$arch")
done
xcrun lipo -create "${launchers[@]}" -output "$app/Contents/MacOS/SwiftyCrow"
cp "$products/libSwiftyCrow.dylib" "$app/Contents/Frameworks/libSwiftyCrow.dylib"
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
for resource_bundle in "$products/"*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done

swift run --package-path "$repo/Tools" swiftycrow-tools check-app \
  --stringsdata "$repo/.build/localized-strings" "${checks[@]}"
xcrun actool "$repo/Resources/Assets.xcassets" --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 26.0 --target-device mac \
  --app-icon "$app_icon" --output-partial-info-plist "$stage/assets.plist" \
  --output-format human-readable-text --warnings --notices
if [[ ! -f "$app/Contents/Resources/Assets.car" || ! -f "$app/Contents/Resources/$app_icon.icns" ]]; then
  echo "Asset compilation did not produce the app assets and icon." >&2
  exit 1
fi
for catalog in "$repo/Resources/"*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$app/Contents/Resources"
done
# Ordinary resource groups are flattened by Xcode's Copy Bundle Resources.
copy_plain_resources() {
  local resource target
  for resource in "$1/"*; do
    [[ -e "$resource" ]] || continue
    case "$resource" in *.xcassets|*.xcstrings) continue ;; esac
    if [[ -d "$resource" ]]; then
      copy_plain_resources "$resource"
    else
      target="$app/Contents/Resources/$(basename "$resource")"
      if [[ -e "$target" ]]; then echo "Duplicate bundle resource: $target" >&2; return 1; fi
      cp "$resource" "$target"
    fi
  done
}
copy_plain_resources "$repo/Resources"
for document in LICENSE THIRD_PARTY_NOTICES.md README.md CHANGELOG.md docs/CONFIGURATION.md docs/LANGUAGE_MODELS.md; do
  cp "$repo/$document" "$app/Contents/Resources/$(basename "$document")"
done
for locale in ko ja zh-Hans zh-Hant; do
  ditto "$repo/docs/$locale" "$app/Contents/Resources/$locale"
done
cp "$repo/App/Info.plist" "$app/Contents/Info.plist"
info="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Merge $stage/assets.plist" "$info"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$info"
plutil -insert CFBundleName -string "$display_name" "$info"
plutil -insert CFBundleDisplayName -string "$display_name" "$info"
plutil -insert CFBundleShortVersionString -string "$version" "$info"
plutil -insert CFBundleVersion -string "$build_number" "$info"
plutil -insert BuildMachineOSBuild -string "$(sw_vers -buildVersion)" "$info"
plutil -insert DTCompiler -string com.apple.compilers.llvm.clang.1_0 "$info"
plutil -insert DTPlatformName -string macosx "$info"
plutil -insert DTPlatformVersion -string "$sdk_version" "$info"
plutil -insert DTPlatformBuild -string "$sdk_build" "$info"
plutil -insert DTSDKName -string "macosx$sdk_version" "$info"
plutil -insert DTSDKBuild -string "$sdk_build" "$info"
plutil -insert DTXcode -string "$xcode_numeric" "$info"
plutil -insert DTXcodeBuild -string "$xcode_build" "$info"
if [[ -n "${SWIFTYCROW_SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  plutil -replace SUPublicEDKey -string "$SWIFTYCROW_SPARKLE_PUBLIC_ED_KEY" "$info"
fi

sign_options=(--force --sign "$identity" --timestamp=none)
if [[ "$configuration" == release ]]; then
  sign_options+=(--options runtime)
  if [[ "$identity" != - ]]; then sign_options=(--force --sign "$identity" --options runtime --timestamp); fi
fi
sign() { codesign "${sign_options[@]}" --preserve-metadata=entitlements "$1"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
sign "$sparkle/XPCServices/Installer.xpc"
sign "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/Frameworks/libSwiftyCrow.dylib"
sign "$app"
codesign --verify --deep --strict "$app"
output="$repo/DerivedData/Build/Products/$display_configuration"
mkdir -p "$output"
if [[ -e "$output/SwiftyCrow.app" ]]; then rm -r "$output/SwiftyCrow.app"; fi
mv "$app" "$output/SwiftyCrow.app"
echo "$output/SwiftyCrow.app"
