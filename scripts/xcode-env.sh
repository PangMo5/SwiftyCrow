#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PangMo5 and contributors
# SPDX-License-Identifier: AGPL-3.0-only

# mise sources this file; select the same Xcode locally and on CI without
# changing the machine-wide xcode-select setting.
swiftycrow_select_xcode() {
  [[ "$(uname -s)" == Darwin ]] || return 0
  local repo version candidate installed_version
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  version="$(cat "$repo/.xcode-version")"
  for candidate in "${DEVELOPER_DIR:-}/../.." /Applications/Xcode*.app; do
    [[ -f "$candidate/Contents/Info.plist" ]] || continue
    installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist")"
    if [[ "$installed_version" == "$version" || "$installed_version" == "$version.0" ]]; then
      DEVELOPER_DIR="$(cd "$candidate/Contents/Developer" && pwd -P)" || return 1
      export DEVELOPER_DIR
      return 0
    fi
  done
  echo "Xcode $version is required. Install it in /Applications before running mise." >&2
  return 1
}

if swiftycrow_select_xcode; then
  unset -f swiftycrow_select_xcode
else
  unset -f swiftycrow_select_xcode
  return 1
fi
