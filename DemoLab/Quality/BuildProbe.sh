#!/bin/bash
# SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail

if [[ $# -lt 2 || ( "$1" != capture && "$1" != tests && "$1" != execution-tests ) || ( "$1" == capture && $# -ne 2 ) ]]; then
  echo "Usage: BuildProbe.sh capture|tests|execution-tests new-output.app [selected-test.swift ...]" >&2
  exit 2
fi
mode=$1
output=$2
shift 2
repo=$(cd "$(dirname "$0")/../.." && pwd)
source "$repo/scripts/xcode-env.sh"
products="$repo/DerivedData/Build/Products/Debug"
spm_products=$(cd "$repo" && swift build --show-bin-path --configuration debug --arch arm64)
app="$products/SwiftyCrow.app"
module="$app/Contents/Frameworks/libSwiftyCrow.dylib"
if [[ -e "$output" ]]; then
  echo "Output exists; use a new path to avoid stale Tart executable caching." >&2
  exit 2
fi
test -f "$module"
while IFS= read -r source; do
  if [[ "$source" -nt "$module" ]]; then
    echo "Source is newer than the app module; run mise run build first: $source" >&2
    exit 1
  fi
done < <(rg --files "$repo/Sources" -g '*.swift')
mkdir -p "$output/Contents/MacOS" "$output/Contents/Frameworks"
cp "$app/Contents/Info.plist" "$output/Contents/Info.plist"
ditto "$app/Contents/Resources" "$output/Contents/Resources"
cp "$module" "$output/Contents/Frameworks/libSwiftyCrow.dylib"
otool -L "$module" | awk 'NR > 1 { print $1 }' | while IFS= read -r library; do
  case "$library" in
    @rpath/libSwiftyCrow.dylib|/System/*|/usr/lib/*) ;;
    @rpath/*.framework/*)
      framework=${library#@rpath/}
      framework=${framework%%/*}
      ditto "$app/Contents/Frameworks/$framework" "$output/Contents/Frameworks/$framework"
      ;;
    *) echo "Unsupported runtime dependency: $library" >&2; exit 1 ;;
  esac
done
sources=()
flags=(-Onone)
if [[ "$mode" == capture ]]; then
  executable=CaptureProbe
  sources=("$repo/DemoLab/Quality/CaptureProbe.swift")
  for name in Runner Metrics Selection RecognitionCache; do
    sources+=("$repo/Tests/CaptureQuality$name.swift")
  done
else
  executable=swiftpm-testing-helper
  sources=("$repo/DemoLab/Quality/TestRunner.swift")
  if [[ $# -gt 0 ]]; then sources+=("$@");
  elif [[ "$mode" == execution-tests ]]; then
    while IFS= read -r source; do sources+=("$source"); done < <(rg --files "$repo/Tests/Execution" -g '*.swift' | LC_ALL=C sort)
  else
    while IFS= read -r source; do sources+=("$source"); done < <(rg --files "$repo/Tests" -g '*.swift' -g '!**/Execution/**' | LC_ALL=C sort)
  fi
  platform="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer"
  plugins="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
  ditto "$platform/Library/Frameworks/Testing.framework" "$output/Contents/Frameworks/Testing.framework"
  cp "$platform/usr/lib/lib_TestingInterop.dylib" "$output/Contents/MacOS/lib_TestingInterop.dylib"
  flags=(-Onone -D DEBUG -F "$platform/Library/Frameworks" -plugin-path "$plugins")
fi
evidence="$output/Contents/Resources/QualityEvidence"
mkdir -p "$evidence/Inputs"
snapshots=()
for index in "${!sources[@]}"; do
  snapshot="$evidence/Inputs/$index-$(basename "${sources[$index]}")"
  cp "${sources[$index]}" "$snapshot"
  snapshots+=("$snapshot")
done
shasum -a 256 "$module" "${sources[@]}" > "$evidence/source-hashes.txt"
while IFS= read -r source; do shasum -a 256 "$source"; done < <(rg --files "$repo/Sources" -g '*.swift' | LC_ALL=C sort) >> "$evidence/source-hashes.txt"
swiftc -parse-as-library -target arm64-apple-macos26.0 -swift-version 5 \
  -I "$spm_products" -F "$spm_products" \
  -Xcc "-fmodule-map-file=$repo/.build/out/Intermediates.noindex/GeneratedModuleMaps/CTomlPlusPlus.modulemap" \
  "${flags[@]}" "${snapshots[@]}" "$output/Contents/Frameworks/libSwiftyCrow.dylib" \
  -Xlinker -rpath -Xlinker @executable_path \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$output/Contents/MacOS/$executable"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable" "$output/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.PangMo5.SwiftyCrow.quality.$mode" "$output/Contents/Info.plist"
codesign --force --deep --sign - "$output"
shasum -a 256 "$output/Contents/MacOS/$executable" >> "$evidence/source-hashes.txt"
jj -R "$repo" log -r @ --no-graph -T 'commit_id ++ "\n"' > "$evidence/revision.txt"
jj -R "$repo" diff --from 'trunk()' --git > "$evidence/worktree.patch"
codesign --force --sign - "$output"
codesign --verify --deep --strict "$output"
echo "$output"
