// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
import CoreVideo
import Foundation
import Metal
@testable import DemoRecorderKit

@Test func cadenceSeparatesLateTimerAndRejectedInput() {
  var accounting = CadenceAccounting()
  #expect(accounting.reserve(elapsed: 0, fps: 30) == 0)
  #expect(accounting.reserve(elapsed: 0.3, fps: 30) == 9)
  accounting.rejectReservedFrame()
  #expect(accounting.reserve(elapsed: 1.0 / 3, fps: 30) == 10)
  #expect(accounting.skippedFrameCount == 8)
  #expect(accounting.rejectedFrameCount == 1)
  #expect(accounting.droppedFrameCount == 9)
}

@Test(arguments: ["hevc", "h264"])
func explicitlySelectedCodecIsPreserved(_ codec: String) throws {
  let command = try RecorderCommand.parse(["--output", "/tmp/codec-test.mov", "--codec", codec, "--fps", "30"])
  guard case .record(let options) = command else { Issue.record("Expected recording command"); return }
  #expect(options.codec.rawValue == codec)
  #expect(options.fps == 30)
}

@Test func unknownCodecFailsInsteadOfChangingCodec() {
  #expect(throws: UsageError.self) {
    try RecorderCommand.parse(["--output", "/tmp/codec-test.mov", "--codec", "automatic"])
  }
}

@Test func backpressurePreservesCollectedPixelsAndTimestampOrder() throws {
  var queue = BoundedFrameQueue<String>(capacity: 3)
  try queue.enqueue(index: 0, payload: "pixels collected at zero")
  #expect(queue.next(encoderReady: false) == nil)
  try queue.enqueue(index: 9, payload: "pixels collected at nine")
  #expect(queue.count == 2)
  #expect(queue.next(encoderReady: true)?.payload == "pixels collected at zero")
  try queue.acknowledge(index: 0)
  #expect(queue.next(encoderReady: true)?.index == 9)
  #expect(queue.next(encoderReady: true)?.payload == "pixels collected at nine")
  // Missing indices 1...8 remain absent rather than being filled later.
  try queue.acknowledge(index: 9)
  #expect(queue.count == 0)
}

@Test func queueBoundAndOrderViolationsFailWithoutReplacingFrames() throws {
  var queue = BoundedFrameQueue<Int>(capacity: 2)
  try queue.enqueue(index: 1, payload: 101)
  #expect(throws: FrameQueueError.nonIncreasingTimestamp) { try queue.enqueue(index: 1, payload: 999) }
  try queue.enqueue(index: 2, payload: 102)
  #expect(throws: FrameQueueError.full) { try queue.enqueue(index: 3, payload: 103) }
  #expect(throws: FrameQueueError.wrongAcknowledgement) { try queue.acknowledge(index: 2) }
  #expect(queue.next(encoderReady: true)?.payload == 101)
  #expect(queue.count == 2)
}

@Test func shutdownRequiresDrainingEveryCollectedFrame() throws {
  var queue = BoundedFrameQueue<Int>(capacity: 2)
  try queue.enqueue(index: 0, payload: 11)
  try queue.enqueue(index: 1, payload: 12)
  queue.finishProducing()
  #expect(!queue.isDrained)
  #expect(throws: FrameQueueError.producerClosed) { try queue.enqueue(index: 2, payload: 13) }
  #expect(queue.next(encoderReady: false) == nil)
  #expect(!queue.isDrained)
  try queue.acknowledge(index: 0)
  #expect(!queue.isDrained)
  try queue.acknowledge(index: 1)
  #expect(queue.isDrained)
}

private func makeMetalTestBuffer() throws -> CVPixelBuffer {
  var source: CVPixelBuffer?
  let attributes: [String: Any] = [
    kCVPixelBufferMetalCompatibilityKey as String: true,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
  ]
  #expect(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &source) == kCVReturnSuccess)
  let buffer = try #require(source)
  CVPixelBufferLockBaseAddress(buffer, [])
  memset(CVPixelBufferGetBaseAddress(buffer), 42, CVPixelBufferGetDataSize(buffer))
  CVPixelBufferUnlockBaseAddress(buffer, [])
  return buffer
}

@Test func metalCopyPreservesPixelsInIndependentStorage() async throws {
  let buffer = try makeMetalTestBuffer()
  let copier = try MetalFrameCopier(width: 4, height: 2, fps: 30)
  let copiedFrame = try copier.copy(buffer)
  try await copier.awaitAllCopies()
  #expect(copiedFrame.state == .completed)
  #expect(!copiedFrame.retainsSourceResources)
  CVPixelBufferLockBaseAddress(buffer, [])
  memset(CVPixelBufferGetBaseAddress(buffer), 99, CVPixelBufferGetDataSize(buffer))
  CVPixelBufferUnlockBaseAddress(buffer, [])
  let copy = copiedFrame.pixelBuffer
  CVPixelBufferLockBaseAddress(copy, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(copy, .readOnly) }
  let copiedBytes = try #require(CVPixelBufferGetBaseAddress(copy)?.assumingMemoryBound(to: UInt8.self))
  #expect(copiedBytes[0] == 42)
  #expect(copiedBytes[CVPixelBufferGetBytesPerRow(copy)] == 42)
}

@Test func metalCopyRetainsResourcesUntilGPUCompletionAndShutdownWaits() async throws {
  let device = try #require(MTLCreateSystemDefaultDevice())
  let queue = try #require(device.makeCommandQueue())
  let gate = try #require(device.makeSharedEvent())
  let blockedCommands = try #require(queue.makeCommandBuffer())
  blockedCommands.encodeWaitForEvent(gate, value: 1)
  blockedCommands.commit()
  defer { gate.signaledValue = 1 }
  let copier = try MetalFrameCopier(width: 4, height: 2, fps: 30, device: device, commandQueue: queue)
  var source: CVPixelBuffer? = try makeMetalTestBuffer()
  weak let sourceReference = source
  let copy = try copier.copy(try #require(source))
  source = nil
  #expect(sourceReference != nil)
  #expect(copy.state == .pending)
  #expect(copy.retainsSourceResources)
  #expect(copier.pendingCopyCount == 1)
  await #expect(throws: RecorderError.self) { try await copier.awaitAllCopies(timeout: .milliseconds(20)) }
  gate.signaledValue = 1
  try await copier.awaitAllCopies()
  #expect(copy.state == .completed)
  #expect(!copy.retainsSourceResources)
  #expect(copier.pendingCopyCount == 0)
}
