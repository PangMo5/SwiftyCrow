// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Foundation
import Testing
@testable import SwiftyCrow

// MARK: - CapturePreviewProgressTests

@MainActor
struct CapturePreviewProgressTests {
  @Test(arguments: [false, true])
  func autoSourceFailureKeepsOriginalAndStopsLoadingWithAnExplicitError(_ missingModel: Bool) async {
    let state = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      RegionCaptureFeature.State(target: .region(.zero))
    }
    state.$settings.withLock {
      $0.languages.source = .auto
      $0.languages.target = Language(code: "ko")
    }
    let store = Store(initialState: state) { RegionCaptureFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.languageDetection = .liveValue
      $0.translation.translateBatch = { _, source, target, _ in
        #expect(source.languageCode?.identifier == "de")
        #expect(target.languageCode?.identifier == "ko")
        return AsyncThrowingStream {
          if missingModel {
            $0.finish(throwing: TranslationModelResolver.ModelError(message: "Required model is not installed."))
          } else {
            $0.finish()
          }
        }
      }
    }
    var line = OCRResult.Line(boundingBoxNormalized: .zero, text: "Künstliche Intelligenz")
    line.recognitionLanguages = ["de"]
    await store.send(.recognized(.init(pngData: Data([1]), size: .zero, lines: [line]), restorationPending: false)).finish()
    #expect(!store.state.isRecognizing && !store.state.isRestoring && !store.state.isTranslating)
    #expect(store.state.lastError != nil)
    #expect(store.state.translationUnavailable == missingModel)
    #expect(store.state.overlayLines[0].isUnavailable)
    #expect(store.state.overlayLines[0].translatedText == nil)
    #expect(!store.state.overlayLines[0].shouldReplaceSourcePixels)
    #expect(store.state.imageData == Data([1]))
  }

  @Test
  func translationCanFinishDuringRestorationButCannotPaintUnrestoredPixels() async {
    var state = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      RegionCaptureFeature.State(target: .region(CGRect(x: 0, y: 0, width: 300, height: 200)))
    }
    state.isRecognizing = true
    state.$settings.withLock {
      $0.languages.source = Language(code: "en")
      $0.languages.target = Language(code: "ko")
    }
    let store = Store(initialState: state) { RegionCaptureFeature() } withDependencies: {
      $0.uuid = .incrementing
      $0.languageDetection = .liveValue
      $0.translation.translateBatch = { lines, _, _, _ in
        AsyncThrowingStream { continuation in
          for line in lines { continuation.yield(.init(id: line.id, text: "번역 완료")) }
          continuation.finish()
        }
      }
    }
    var line = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1), text: "Open the settings")
    let size = CGSize(width: 300, height: 200)
    await store.send(.recognized(.init(pngData: nil, size: size, lines: [line]))).finish()
    let id = store.state.overlayLines[0].id
    #expect(store.state.isRestoring)
    #expect(store.state.overlayLines[0].translatedText == "번역 완료")
    #expect(!store.state.overlayLines[0].shouldReplaceSourcePixels)
    // The preview may finish encoding after recognition. It must not clear
    // translations, and final masks must update the same line identity.
    store.send(.capturePreviewReady(Data([1]), size))
    line.replacementPatches = [.init(box: line.boundingBoxNormalized)]
    await store.send(.captured(.success(.init(pngData: Data([1]), size: size, lines: [line])))).finish()
    #expect(!store.state.isRestoring)
    #expect(store.state.overlayLines[0].id == id)
    #expect(store.state.overlayLines[0].translatedText == "번역 완료")
    #expect(store.state.overlayLines[0].shouldReplaceSourcePixels)
    #expect(store.state.overlayLines[0].source.replacementPatches == line.replacementPatches)
  }

  @Test
  func restorationFailureDiscardsProvisionalTranslationsAndLateResponses() async {
    var state = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      RegionCaptureFeature.State(target: .region(.zero))
    }
    state.isRestoring = true
    state.imageData = Data([1])
    let store = Store(initialState: state) { RegionCaptureFeature() }
    await store.send(.captured(.failure(CocoaError(.coderInvalidValue)))).finish()
    store.send(.recognized(.init(pngData: nil, size: .zero, lines: [
      .init(boundingBoxNormalized: .zero, text: "Late recognition")
    ])))
    store.send(.translationResponse(id: UUID(), translation: .init(text: "late"), target: Locale.Language(identifier: "ko")))
    #expect(store.state.overlayLines.isEmpty)
    #expect(store.state.imageData == Data([1]))
    #expect(!store.state.isRestoring)
  }

  @Test
  func originalPreviewIsAvailableWhileOCRRunsAndSurvivesAnOCRFailure() async {
    var state = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      RegionCaptureFeature.State(target: .region(CGRect(x: 0, y: 0, width: 300, height: 200)))
    }
    state.isRecognizing = true
    let store = TestStore(initialState: state) { RegionCaptureFeature() }
    let image = Data([1, 2, 3])
    let size = CGSize(width: 300, height: 200)
    await store.send(.capturePreviewReady(image, size)) {
      $0.imageData = image
      $0.imageSize = size
    }
    await store.send(.captureIsTakingLong) { $0.isTakingLong = true }
    let error = DeadlineExceededError(stage: .ocr)
    await store.send(.captured(.failure(error))) {
      $0.isRecognizing = false
      $0.isTakingLong = false
      $0.lastError = error.localizedDescription
    }
    #expect(store.state.imageData == image)
    #expect(store.state.imageSize == size)
  }
}

// MARK: - CapturePresentationTests

/// These tests exercise real AppKit windows and NSApp activation state.
@Suite(.serialized)
@MainActor
struct CapturePresentationTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func resultWindowWaitsForSourceAcquisition(_ fails: Bool) async throws {
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
        if fails { throw ScreenCaptureError.unreadableImage }
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
  func replacingAPendingCaptureCannotPresentItsLateResult() async throws {
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
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
