// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Testing
@testable import SwiftyCrow

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
