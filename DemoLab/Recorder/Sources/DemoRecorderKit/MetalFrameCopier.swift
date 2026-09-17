// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreVideo
import Foundation
import Metal

/// A pixel snapshot becomes consumable only after its GPU copy completes.
final class MetalCopiedFrame: @unchecked Sendable {
  enum State: Equatable {
    case pending
    case completed
    case failed(String)
  }

  init(source: CVPixelBuffer, destination: CVPixelBuffer, sourceTexture: CVMetalTexture, destinationTexture: CVMetalTexture) {
    pixelBuffer = destination
    resources = Resources(source: source, destination: destination, sourceTexture: sourceTexture, destinationTexture: destinationTexture)
  }

  let pixelBuffer: CVPixelBuffer
  var state: State { lock.withLock { storedState } }
  var retainsSourceResources: Bool { lock.withLock { resources != nil } }

  func complete(error: String?) {
    lock.withLock {
      storedState = error.map(State.failed) ?? .completed
      resources = nil
    }
  }

  private struct Resources {
    let source: CVPixelBuffer
    let destination: CVPixelBuffer
    let sourceTexture: CVMetalTexture
    let destinationTexture: CVMetalTexture
  }
  private let lock = NSLock()
  private var resources: Resources?
  private var storedState = State.pending
}

/// A bounded, Metal-only image copy. Neither source nor destination is CPU
/// locked. Both buffers and both CVMetalTexture wrappers stay alive until the
/// GPU completion handler releases them. There is no CPU fallback.
final class MetalFrameCopier: @unchecked Sendable {
  init(width: Int, height: Int, fps: Int, device suppliedDevice: MTLDevice? = nil, commandQueue suppliedQueue: MTLCommandQueue? = nil) throws {
    self.width = width
    self.height = height
    capacity = max(1, min(fps, 256 * 1024 * 1024 / (width * height * 4)))
    allocationLimit = 2 * capacity + 2
    guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice(),
          let commandQueue = suppliedQueue ?? device.makeCommandQueue() else {
      throw RecorderError.writerSetupFailed("A Metal device and command queue are required for recording")
    }
    self.commandQueue = commandQueue
    var cache: CVMetalTextureCache?
    let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    guard cacheResult == kCVReturnSuccess, let cache else {
      throw RecorderError.writerSetupFailed("Could not create the Metal texture cache: \(cacheResult)")
    }
    textureCache = cache
    var created: CVPixelBufferPool?
    let attributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let result = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
    guard result == kCVReturnSuccess, let created else {
      throw RecorderError.writerSetupFailed("Could not create the Metal BGRA copy pool: \(result)")
    }
    pool = created
  }

  let capacity: Int
  let allocationLimit: Int
  var slowOperations: [String] { lock.withLock { storedSlowOperations } }
  var omittedSlowOperations: Int { lock.withLock { storedOmittedSlowOperations } }
  var pendingCopyCount: Int { lock.withLock { pendingCopies } }

  func copy(_ source: CVPixelBuffer, frameIndex: Int = 0) throws -> MetalCopiedFrame {
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
          CVPixelBufferGetWidth(source) == width,
          CVPixelBufferGetHeight(source) == height,
          !CVPixelBufferIsPlanar(source) else {
      throw RecorderError.writerFailed("Capture buffer is not the expected \(width)x\(height) BGRA image")
    }
    var destination: CVPixelBuffer?
    let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationLimit]
    let allocation = timed("pool_allocation", frameIndex: frameIndex) {
      CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary as CFDictionary, &destination)
    }
    guard allocation == kCVReturnSuccess, let destination else {
      throw RecorderError.writerFailed("Metal copy pool reached its bound or allocation failed: \(allocation)")
    }
    let sourceWrapper = try timed("source_texture", frameIndex: frameIndex) { try texture(for: source) }
    let destinationWrapper = try timed("destination_texture", frameIndex: frameIndex) { try texture(for: destination) }
    guard let sourceTexture = CVMetalTextureGetTexture(sourceWrapper),
          let destinationTexture = CVMetalTextureGetTexture(destinationWrapper),
          let commands = commandQueue.makeCommandBuffer(),
          let blit = commands.makeBlitCommandEncoder() else {
      throw RecorderError.writerFailed("Could not create Metal textures or a blit command encoder")
    }
    commands.label = "SwiftyCrow capture frame \(frameIndex)"
    blit.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
              to: destinationTexture, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    CVBufferPropagateAttachments(source, destination)
    let frame = MetalCopiedFrame(source: source, destination: destination, sourceTexture: sourceWrapper, destinationTexture: destinationWrapper)
    let startedAt = DispatchTime.now().uptimeNanoseconds
    lock.withLock { pendingCopies += 1 }
    commands.addCompletedHandler { [self, frame] completed in
      let error = completed.status == .completed ? nil : "Metal copy failed: \(completed.error?.localizedDescription ?? String(describing: completed.status))"
      frame.complete(error: error)
      recordSlow(stage: "gpu_completion", frameIndex: frameIndex, start: startedAt)
      lock.withLock {
        pendingCopies -= 1
        if let error { gpuFailure = error }
      }
    }
    timed("command_commit", frameIndex: frameIndex) { commands.commit() }
    return frame
  }

  /// Producer shutdown must be followed by completion of all submitted GPU
  /// copies, including a copy whose queue insertion subsequently failed.
  func awaitAllCopies(timeout: Duration = .seconds(5)) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      let state = lock.withLock { (pendingCopies, gpuFailure) }
      if state.0 == 0 {
        if let failure = state.1 { throw RecorderError.writerFailed(failure) }
        return
      }
      guard ContinuousClock.now < deadline else { throw RecorderError.writerFailed("Metal copies did not finish before shutdown deadline") }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private let width: Int
  private let height: Int
  private let pool: CVPixelBufferPool
  private let textureCache: CVMetalTextureCache
  private let commandQueue: MTLCommandQueue
  private let lock = NSLock()
  private var pendingCopies = 0
  private var gpuFailure: String?
  private var storedSlowOperations: [String] = []
  private var storedOmittedSlowOperations = 0

  private func texture(for buffer: CVPixelBuffer) throws -> CVMetalTexture {
    var wrapped: CVMetalTexture?
    let result = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &wrapped)
    guard result == kCVReturnSuccess, let wrapped else { throw RecorderError.writerFailed("BGRA Metal texture mapping failed: \(result)") }
    return wrapped
  }

  private func timed<Result>(_ stage: String, frameIndex: Int, _ operation: () throws -> Result) rethrows -> Result {
    let start = DispatchTime.now().uptimeNanoseconds
    defer { recordSlow(stage: stage, frameIndex: frameIndex, start: start) }
    return try operation()
  }

  private func recordSlow(stage: String, frameIndex: Int, start: UInt64) {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    guard elapsed >= 0.005 else { return }
    lock.withLock {
      if storedSlowOperations.count < 256 {
        storedSlowOperations.append("metal_copy frame_index=\(frameIndex) stage=\(stage) seconds=\(elapsed) uptime_ns=\(start)")
      } else {
        storedOmittedSlowOperations += 1
      }
    }
  }
}
