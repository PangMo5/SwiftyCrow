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
module="$source/Contents/Frameworks/libSwiftyCrow.dylib"
test -f "$module"
while IFS= read -r input; do
  if [[ "$input" -nt "$module" ]]; then
    echo "Source is newer than the app module; run mise run build first: $input" >&2
    exit 1
  fi
done < <(rg --files "$repo/Sources" -g '*.swift')
identity=$(codesign -d --verbose=4 "$source" 2>&1 | sed -n 's/^Authority=\(Apple Development:.*\)/\1/p')
if [[ -z "$identity" ]]; then
  echo "Native QA requires the app's Apple Development identity; ad-hoc signing invalidates persistent capture grants." >&2
  exit 1
fi
ditto "$source" "$output"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.PangMo5.SwiftyCrow.qa.native' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SwiftyCrow QA' "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName SwiftyCrow QA' "$output/Contents/Info.plist"
# Keep the actual app's signed frameworks and SwiftPM module. Sign only the app
# identity, so the module's bytes match the production build exactly.
codesign --force --sign "$identity" "$output"
codesign --verify --deep --strict "$output"
cmp "$module" "$output/Contents/Frameworks/libSwiftyCrow.dylib"
codesign -d -r- "$output" 2> "$output/Contents/Resources/qa-signing-requirement.txt"
shasum -a 256 "$output/Contents/Frameworks/libSwiftyCrow.dylib" > "$output/Contents/Resources/qa-module-hash.txt"
codesign --force --sign "$identity" "$output"
codesign --verify --deep --strict "$output"
echo "$output"
