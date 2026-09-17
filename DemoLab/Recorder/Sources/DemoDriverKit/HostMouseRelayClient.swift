// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Darwin
import Foundation

/// A connection to the owned VM's native host input service. It never falls
/// back to guest event injection after the host input route has been selected.
public final class HostMouseRelayClient: @unchecked Sendable {

  // MARK: Lifecycle

  public init(configuration: Configuration) throws {
    guard configuration.port > 0, UUID(uuidString: configuration.token) != nil else {
      throw InteractionError("Invalid host mouse relay configuration")
    }
    self.configuration = configuration
    descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { throw InteractionError("Could not create host mouse socket: \(errno)") }
    var retained = false
    defer { if !retained { Darwin.close(descriptor)
      descriptor = -1
    } }
    var one: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    var timeout = timeval(tv_sec: 12, tv_usec: 0)
    _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = configuration.port.bigEndian
    guard configuration.host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
      throw InteractionError("Host mouse relay requires an IPv4 address")
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw InteractionError("Could not configure host mouse connection")
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result != 0 {
      guard errno == EINPROGRESS else { throw InteractionError("Could not connect to host mouse relay: \(errno)") }
      var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      guard Darwin.poll(&pending, 1, 5_000) == 1 else { throw InteractionError("Host mouse connection timed out") }
      var error: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else {
        throw InteractionError("Could not connect to host mouse relay: \(error)")
      }
    }
    guard fcntl(descriptor, F_SETFL, flags) == 0 else { throw InteractionError("Could not finalize host mouse connection") }
    retained = true
  }

  deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

  // MARK: Public

  public struct Configuration: Codable, Sendable {
    public init(host: String, port: UInt16, token: String) {
      self.host = host
      self.port = port
      self.token = token
    }

    public let host: String
    public let port: UInt16
    public let token: String

  }

  public static let environmentKey = "SWIFTYCROW_HOST_MOUSE_CONFIG"

  public static func fromEnvironment() throws -> HostMouseRelayClient? {
    guard let path = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    return try HostMouseRelayClient(configuration: configuration)
  }

  /// Clock measurements deliberately use a fresh request and host receipt time.
  /// The caller brackets this operation with its own DispatchTime timestamps.
  public static func clockUptimeNanoseconds() throws -> UInt64 {
    guard let client = try fromEnvironment() else { throw InteractionError("Missing host mouse relay configuration") }
    let response = try client.request(operation: "clock")
    guard let value = response["hostUptimeNanoseconds"] as? NSNumber else {
      throw InteractionError("Host clock response is missing its timestamp")
    }
    return value.uint64Value
  }

  public func move(to point: CGPoint) throws {
    _ = try request(operation: "move", point: point)
  }

  public func click(at point: CGPoint) throws {
    _ = try request(operation: "click", point: point)
  }

  public func drag(from point: CGPoint, to end: CGPoint) throws {
    _ = try request(operation: "drag", point: point, end: end)
  }

  public func scroll(at point: CGPoint, pixels: Int) throws {
    _ = try request(operation: "scroll", point: point, pixels: pixels)
  }

  public func sessionMetadata() throws -> [String: Any] {
    guard let metadata = try request(operation: "metadata")["metadata"] as? [String: Any] else {
      throw InteractionError("Host input response is missing session metadata")
    }
    return metadata
  }

  // MARK: Private

  private var descriptor: Int32
  private let configuration: Configuration
  private let lock = NSLock()

  private func request(
    operation: String,
    point: CGPoint? = nil,
    end: CGPoint? = nil,
    pixels: Int? = nil
  ) throws -> [String: Any] {
    try lock.withLock {
      let id = UUID().uuidString
      var request: [String: Any] = ["id": id, "token": configuration.token, "operation": operation]
      if let point { request["x"] = point.x
        request["y"] = point.y
      }
      if let end { request["toX"] = end.x
        request["toY"] = end.y
      }
      if let pixels { request["pixels"] = pixels }
      var bytes = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
      bytes.append(10)
      try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
          let count = Darwin.send(descriptor, raw.baseAddress! + offset, raw.count - offset, 0)
          guard count > 0 else { throw InteractionError("Host input request write failed: \(errno)") }
          offset += count
        }
      }
      var response = Data()
      var byte: UInt8 = 0
      while response.count < 65_536 {
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        guard count == 1 else { throw InteractionError("Host input response read failed: \(errno)") }
        if byte == 10 { break }
        response.append(byte)
      }
      guard
        response.count < 65_536,
        let value = try JSONSerialization.jsonObject(with: response) as? [String: Any],
        value["id"] as? String == id
      else { throw InteractionError("Malformed or mismatched host input response") }
      guard value["success"] as? Bool == true else {
        throw InteractionError(value["error"] as? String ?? "Host input request failed")
      }
      return value
    }
  }
}
