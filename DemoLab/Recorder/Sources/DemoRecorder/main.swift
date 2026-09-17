// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoRecorderKit
import Dispatch
import Foundation

// DemoRecorder — a 60 fps ScreenCaptureKit display recorder that writes a .mov.
//
// This file is deliberately only a shell. Both recording and display listing
// finish on background tasks — ScreenCaptureKit delivers frames to a queue and
// AVAssetWriter finalizes asynchronously — so the process parses its arguments,
// hands off to DemoRecorderKit, and parks the main thread in `dispatchMain()`.
// Every exit runs through the kit, which finalizes the file first: exiting
// straight out of a signal handler leaves the moov atom unwritten and the .mov
// unplayable.

do {
  switch try RecorderCommand.parse(Array(CommandLine.arguments.dropFirst())) {
  case .help:
    print(RecorderCommand.usage)
    exit(RecorderExit.ok.rawValue)

  case .preflight:
    // How the VM bootstrap verifies the TCC grant without recording anything.
    let granted = ScreenAccess.isGranted()
    print("screen-recording-access: \(granted ? "granted" : "denied")")
    guard granted else {
      StandardError.write(ScreenAccess.deniedMessage)
      exit(RecorderExit.noScreenRecordingAccess.rawValue)
    }
    exit(RecorderExit.ok.rawValue)

  case .listDisplays:
    DisplayCatalog.printCatalogAndExit()

  case .record(let options):
    RecorderController(options: options).run()
  }
} catch let error as UsageError {
  StandardError.write("DemoRecorder: \(error.description)")
  StandardError.write(RecorderCommand.usage)
  exit(RecorderExit.usage.rawValue)
} catch {
  StandardError.write("DemoRecorder: \(StandardError.describe(error))")
  exit(RecorderExit.captureFailure.rawValue)
}

dispatchMain()
