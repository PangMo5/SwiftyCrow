// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Foundation
import Testing
@testable import SwiftyCrow

// MARK: - CapturePresentationTests

/// These tests exercise real AppKit windows and NSApp activation state.
@Suite(.serialized)
@MainActor
struct CapturePresentationTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func `result window waits for source acquisition`(_ fails: Bool) async throws {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let image = try fixtureImage()
    let controller = withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.continuousClock = TestClock()
      $0.languageDetection = .liveValue
      $0.screenCapture.captureImage = { _, _, excludedPID in
        #expect(!captureRunsOnMainThread())
        #expect(excludedPID == ProcessInfo.processInfo.processIdentifier)
        started.continuation.yield(())
        for await _ in release.stream { break }
        if fails {
          throw ScreenCaptureError.unreadableImage
        }
        return image
      }
      $0.ocr.recognizeCapture = { _, _, _ in
        #expect(!captureRunsOnMainThread())
        return OCRResult(lines: [])
      }
    } operation: {
      let controller = RegionResultWindowController()
      controller.present(target: .region(CGRect(x: 0, y: 0, width: 32, height: 32)))
      return controller
    }
    let panel = try #require(controller.panel)
    #expect(!panel.isReleasedWhenClosed)
    let task = try #require(controller.captureTask)
    defer { panel.close() }
    for await _ in started.stream { break }
    #expect(!panel.isVisible)
    release.continuation.yield(())
    release.continuation.finish()
    await task.finish()
    #expect(panel.isVisible)
    panel.close()
    #expect(controller.panel == nil)
    #expect(controller.captureTask == nil)
  }

  @Test
  func `replacing A pending capture cannot present its late result`() async throws {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let image = try fixtureImage()
    let controller = withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.continuousClock = TestClock()
      $0.languageDetection = .liveValue
      $0.screenCapture.captureImage = { frame, _, _ in
        if frame?.width == 32 {
          started.continuation.yield(())
          for await _ in release.stream { break }
        }
        return image
      }
      $0.ocr.recognizeCapture = { _, _, _ in OCRResult(lines: []) }
    } operation: {
      let controller = RegionResultWindowController()
      controller.present(target: .region(CGRect(x: 0, y: 0, width: 32, height: 32)))
      return controller
    }
    let previousPanel = try #require(controller.panel)
    let previousTask = try #require(controller.captureTask)
    for await _ in started.stream { break }
    #expect(!previousPanel.isVisible)
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.continuousClock = TestClock()
      $0.languageDetection = .liveValue
      $0.screenCapture.captureImage = { _, _, _ in image }
      $0.ocr.recognizeCapture = { _, _, _ in OCRResult(lines: []) }
    } operation: {
      controller.present(target: .region(CGRect(x: 0, y: 0, width: 64, height: 32)))
    }
    let currentPanel = try #require(controller.panel)
    let currentTask = try #require(controller.captureTask)
    defer { currentPanel.close() }
    release.continuation.yield(())
    release.continuation.finish()
    await previousTask.finish()
    await currentTask.finish()
    #expect(controller.panel === currentPanel)
    #expect(!previousPanel.isVisible)
    #expect(currentPanel.isVisible)
  }

  // MARK: Private

  private func fixtureImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 32,
      height: 32,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    return try #require(context.makeImage())
  }

}

/// A synchronous probe observes the current thread without suggesting that an
/// async function has a stable thread identity across suspension points.
private func captureRunsOnMainThread() -> Bool {
  Thread.isMainThread
}
