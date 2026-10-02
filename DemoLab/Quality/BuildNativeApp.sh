#!/bin/bash
# SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
if [[ $# -ne 1 || -e "$1" ]]; then
  echo "Usage: BuildNativeApp.sh new-output.app" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/../.." && pwd)
source="$repo/DerivedData/Build/Products/Debug/SwiftyCrow.app"
output=$1
module="$source/Contents/MacOS/SwiftyCrow.debug.dylib"
while IFS= read -r input; do
  if [[ "$input" -nt "$module" ]]; then
    echo "Source is newer than the app module; rebuild with XcodeBuildMCP first: $input" >&2
    exit 1
  fi
done < <(rg --files "$repo/Sources" -g '*.swift')
identity=$(codesign -d --verbose=4 "$source" 2>&1 | sed -n 's/^Authority=\(Apple Development:.*\)/\1/p')
if [[ -z "$identity" ]]; then
  echo "Native QA requires the app's Apple Development identity; ad-hoc signing invalidates persistent capture grants." >&2
  exit 1
fi
ditto "$source" "$output"
# Xcode embeds the unit-test runner in the host app during testing. It is not
# part of the normal app and must not become a native QA runtime dependency.
for test_bundle in "$output/Contents/PlugIns/"*.xctest; do
  [[ -d "$test_bundle" ]] || continue
  rm -rf "$test_bundle"
done
# A test run also injects XCTest frameworks, including SDK-local symlinks.
# Reconstruct this fresh copy's runtime from the actual app module's linkage.
rm -rf "$output/Contents/Frameworks"
mkdir -p "$output/Contents/Frameworks"
otool -L "$module" | awk 'NR > 1 { print $1 }' | while IFS= read -r library; do
  case "$library" in
    @rpath/SwiftyCrow.debug.dylib|/System/*|/usr/lib/*) ;;
    @rpath/*.framework/*)
      framework=${library#@rpath/}
      framework=${framework%%/*}
      ditto "$source/Contents/Frameworks/$framework" "$output/Contents/Frameworks/$framework"
      ;;
    *) echo "Unsupported runtime dependency: $library" >&2; exit 1 ;;
  esac
done
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.PangMo5.SwiftyCrow.qa.native' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SwiftyCrow QA' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName SwiftyCrow QA' "$output/Contents/Info.plist"
# Keep the actual app's signed frameworks and Debug module. Sign only the app
# identity, so the module's bytes match the production build exactly.
codesign --force --sign "$identity" "$output"
codesign --verify --deep --strict "$output"
cmp "$source/Contents/MacOS/SwiftyCrow.debug.dylib" "$output/Contents/MacOS/SwiftyCrow.debug.dylib"
codesign -d -r- "$output" 2> "$output/Contents/Resources/qa-signing-requirement.txt"
shasum -a 256 "$output/Contents/MacOS/SwiftyCrow.debug.dylib" > "$output/Contents/Resources/qa-module-hash.txt"
codesign --force --sign "$identity" "$output"
codesign --verify --deep --strict "$output"
echo "$output"
