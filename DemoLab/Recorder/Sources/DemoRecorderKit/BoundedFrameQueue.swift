// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

// MARK: - FrameQueueError

enum FrameQueueError: Error, Equatable, CustomStringConvertible {
  case full
  case producerClosed
  case nonIncreasingTimestamp
  case wrongAcknowledgement

  var description: String {
    switch self {
    case .full: "Collected frame queue reached its explicit capacity"
    case .producerClosed: "Frame producer is already closed"
    case .nonIncreasingTimestamp: "Frame timestamps must increase strictly"
    case .wrongAcknowledgement: "Encoder acknowledged a frame out of order"
    }
  }
}

// MARK: - BoundedFrameQueue

/// The producer owns timestamps. Readiness only controls consumption; it never
/// changes, replaces, or invents a frame. The caller serializes access.
struct BoundedFrameQueue<Payload> {

  // MARK: Lifecycle

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  // MARK: Internal

  struct Frame {
    let index: Int
    let payload: Payload
  }

  let capacity: Int
  private(set) var producerClosed = false

  var count: Int {
    frames.count
  }

  var isEmpty: Bool {
    frames.isEmpty
  }

  var isDrained: Bool {
    producerClosed && frames.isEmpty
  }

  mutating func enqueue(index: Int, payload: Payload) throws {
    guard !producerClosed else { throw FrameQueueError.producerClosed }
    guard frames.count < capacity else { throw FrameQueueError.full }
    guard lastIndex.map({ index > $0 }) ?? true else { throw FrameQueueError.nonIncreasingTimestamp }
    frames.append(Frame(index: index, payload: payload))
    lastIndex = index
  }

  func next(encoderReady: Bool) -> Frame? {
    encoderReady ? frames.first : nil
  }

  mutating func acknowledge(index: Int) throws {
    guard frames.first?.index == index else { throw FrameQueueError.wrongAcknowledgement }
    frames.removeFirst()
  }

  mutating func finishProducing() {
    producerClosed = true
  }

  // MARK: Private

  private var frames = [Frame]()
  private var lastIndex: Int?

}
