// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import DemoDriverKit
import Foundation
import ScreenCaptureKit

// MARK: - Viewport

private struct Viewport: Codable, Sendable {
  let ownerPID: Int32
  let windowID: UInt32
  let displayID: UInt32
  let title: String
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let scale: Double
}

// MARK: - Request

private struct Request: Decodable, Sendable {
  let id: String
  let token: String
  let operation: String
  let x: Double?
  let y: Double?
  let toX: Double?
  let toY: Double?
  let pixels: Int?
}

// MARK: - InputService

@MainActor
private final class InputService {

  // MARK: Lifecycle

  init(viewport: Viewport, peer: String, logDirectory: URL) async throws {
    guard
      ProcessInfo.processInfo.environment[HostMouseRelayClient.environmentKey] == nil,
      AXIsProcessTrusted()
    else { throw InteractionError("Host service requires local trusted input without relay configuration") }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard
      let sourceWindow = content.windows.first(where: {
        $0.windowID == viewport.windowID && $0.owningApplication?.processID == viewport.ownerPID && $0.title == viewport.title
      }), let display = content.displays.first(where: { $0.displayID == viewport.displayID }),
      abs(viewport.width * viewport.scale - 1920) < 0.001,
      abs(viewport.height * viewport.scale - 1200) < 0.001,
      abs(Double(SCContentFilter(display: display, including: [sourceWindow]).pointPixelScale) - viewport.scale) < 0.001
    else { throw InteractionError("Owned VM window or native pixel geometry is unavailable") }
    rectangle = CGRect(
      x: viewport.x + display.frame.minX,
      y: viewport.y + display.frame.minY,
      width: viewport.width,
      height: viewport.height
    )
    guard sourceWindow.frame.contains(rectangle), display.frame.contains(rectangle) else {
      throw InteractionError("Owned viewport is outside its window or display")
    }
    let root = AXUIElementCreateApplication(viewport.ownerPID)
    guard
      let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement],
      let window = windows.first(where: { Self.attribute($0, kAXTitleAttribute) as? String == viewport.title })
    else { throw InteractionError("Owned VM Accessibility window is unavailable") }
    let frame = try Self.frame(window)
    guard frame == sourceWindow.frame
    else { throw InteractionError("Window geometry disagrees between Accessibility and capture") }
    self.viewport = viewport
    self.window = window
    self.peer = peer
    originalFrame = frame
    binaryHash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(
      format: "%02x",
      $0
    ) }.joined()
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let url = logDirectory.appendingPathComponent("host-input-\(sessionID).jsonl")
    guard FileManager.default.createFile(atPath: url.path, contents: nil)
    else { throw InteractionError("Could not create host input trace") }
    log = try FileHandle(forWritingTo: url)
    NativeInteractionDriver.setInputValidation { [weak self] in
      guard let self else { throw InteractionError("Host input session has ended") }
      try validate()
    }
    try append(["event": "sessionStarted", "metadata": metadata()])
  }

  // MARK: Internal

  let viewport: Viewport
  let window: AXUIElement
  let originalFrame: CGRect
  let rectangle: CGRect
  let sessionID = UUID().uuidString
  let binaryHash: String
  let peer: String
  let log: FileHandle
  var requestCount = 0
  var lastAction: UInt64 = 0

  static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  static func frame(_ window: AXUIElement) throws -> CGRect {
    guard
      let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
      let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
    else { throw InteractionError("Owned VM window frame is unavailable") }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard
      AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
      AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions)
    else { throw InteractionError("Could not read owned VM frame") }
    return CGRect(origin: point, size: dimensions)
  }

  nonisolated static func encoded(_ value: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{\"success\":false}".utf8)
    data.append(10)
    return data
  }

  func validate() throws {
    guard
      NSWorkspace.shared.frontmostApplication?.processIdentifier == viewport.ownerPID,
      Self.attribute(window, kAXTitleAttribute) as? String == viewport.title,
      try Self.frame(window) == originalFrame
    else { throw InteractionError("Owned VM focus or geometry changed; host input rejected") }
  }

  func metadata() -> [String: Any] {
    [
      "hostInputSessionUUID": sessionID,
      "serverBinarySHA256": binaryHash,
      "route": "native host cursor through owned Tart VM view",
      "peerVMTitle": viewport.title,
      "peerIPv4": peer,
      "guestWidth": 1920,
      "guestHeight": 1200,
      "viewport": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(viewport))) ?? [:],
      "requestCount": requestCount,
      "lastActionUptimeNanoseconds": String(lastAction),
      "traceFile": "host-input-\(sessionID).jsonl",
    ]
  }

  func append(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    try log.write(contentsOf: data)
  }

  func mapped(_ x: Double?, _ y: Double?) throws -> CGPoint {
    guard let x, let y, x.isFinite, y.isFinite, x >= 0, y >= 0, x < 1920, y < 1200 else {
      throw InteractionError("Host input coordinates are outside the owned guest viewport")
    }
    return CGPoint(x: rectangle.minX + x / viewport.scale, y: rectangle.minY + y / viewport.scale)
  }

  func handle(_ request: Request, received: UInt64) -> Data {
    var response: [String: Any] = ["id": request.id, "success": false, "hostUptimeNanoseconds": received]
    var trace: [String: Any] = [
      "requestID": request.id,
      "operation": request.operation,
      "hostStartUptimeNanoseconds": String(received),
    ]
    do {
      if request.operation == "metadata" { response["metadata"] = metadata() }
      else {
        guard ["move", "click", "drag", "scroll"].contains(request.operation)
        else { throw InteractionError("Unknown host input operation") }
        let point = try mapped(request.x, request.y)
        let end = request.operation == "drag" ? try mapped(request.toX, request.toY) : point
        if request.operation == "scroll" {
          guard
            let pixels = request.pixels,
            (-10_000...10_000).contains(pixels)
          else { throw InteractionError("Invalid host scroll distance") }
        }
        guard let app = NSRunningApplication(processIdentifier: viewport.ownerPID)
        else { throw InteractionError("Owned VM has exited") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != viewport.ownerPID {
          guard app.activate() else { throw InteractionError("Could not activate owned VM") }
          let deadline = Date().addingTimeInterval(2)
          while
            NSWorkspace.shared.frontmostApplication?.processIdentifier != viewport.ownerPID,
            Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        }
        try validate()
        if let cursor = CGEvent(source: nil)?.location, !rectangle.contains(cursor) {
          guard CGWarpMouseCursorPosition(point) == .success else { throw InteractionError("Could not enter owned VM viewport") }
        }
        requestCount += 1
        trace["guestX"] = request.x
        trace["guestY"] = request.y
        trace["guestToX"] = request.toX
        trace["guestToY"] = request.toY
        trace["pixels"] = request.pixels
        switch request.operation {
        case "move": try NativeInteractionDriver.movePointer(to: point)
        case "click": try NativeInteractionDriver.click(at: point)
        case "drag": try NativeInteractionDriver.drag(from: point, to: end)
        case "scroll": try NativeInteractionDriver.scroll(at: point, pixels: request.pixels!)
        default: break
        }
        try validate()
        guard let actual = CGEvent(source: nil)?.location, abs(actual.x - end.x) <= 1, abs(actual.y - end.y) <= 1 else {
          throw InteractionError("Native host cursor did not reach the requested guest point")
        }
        lastAction = DispatchTime.now().uptimeNanoseconds
        trace["hostEndUptimeNanoseconds"] = String(lastAction)
        trace["success"] = true
        try append(trace)
      }
      response["success"] = true
    } catch {
      response["error"] = String(describing: error)
      trace["success"] = false
      trace["error"] = String(describing: error)
      trace["hostEndUptimeNanoseconds"] = String(DispatchTime.now().uptimeNanoseconds)
      try? append(trace)
    }
    return Self.encoded(response)
  }

}

// MARK: - SocketService

private enum SocketService {
  static func listen(host: String, peer: String, token: String, configurationURL: URL, input: InputService) throws {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard listener >= 0 else { throw InteractionError("Could not create host input listener") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1
    else { throw InteractionError("Invalid bind IPv4") }
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(
      listener,
      $0,
      socklen_t(MemoryLayout<sockaddr_in>.size)
    ) } }
    guard result == 0, Darwin.listen(listener, 8) == 0 else { Darwin.close(listener)
      throw InteractionError("Could not bind host input listener")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard
      withUnsafeMutablePointer(
        to: &address,
        { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
      ) == 0
    else {
      Darwin.close(listener)
      throw InteractionError("Could not read host input listener")
    }
    let config = HostMouseRelayClient.Configuration(host: host, port: UInt16(bigEndian: address.sin_port), token: token)
    let data = try JSONEncoder().encode(config)
    guard FileManager.default.createFile(atPath: configurationURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      Darwin.close(listener)
      throw InteractionError("Could not write private input configuration")
    }
    let capacity = DispatchSemaphore(value: 8)
    DispatchQueue.global(qos: .userInteractive).async {
      while true {
        var remote = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let client = withUnsafeMutablePointer(to: &remote) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(
          listener,
          $0,
          &size
        ) } }
        guard client >= 0 else { continue }
        var expected = in_addr()
        guard
          peer.withCString({ inet_pton(AF_INET, $0, &expected) }) == 1,
          remote.sin_addr.s_addr == expected.s_addr, capacity.wait(timeout: .now()) == .success
        else { Darwin.close(client)
          continue
        }
        DispatchQueue.global(qos: .userInteractive).async {
          defer { Darwin.close(client)
            capacity.signal()
          }
          var one: Int32 = 1
          _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
          _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
          var timeout = timeval(tv_sec: 120, tv_usec: 0)
          _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
          timeout.tv_sec = 12
          _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
          while true {
            var bytes = Data()
            var byte: UInt8 = 0
            while bytes.count < 4096 {
              guard Darwin.recv(client, &byte, 1, 0) == 1 else { return }
              if byte == 10 { break }
              bytes.append(byte)
            }
            let received = DispatchTime.now().uptimeNanoseconds
            guard
              bytes.count < 4096, let request = try? JSONDecoder().decode(Request.self, from: bytes),
              UUID(uuidString: request.id) != nil
            else { return }
            let response: Data =
              if request.token != token {
                InputService.encoded(["id": request.id, "success": false, "error": "Host input authentication failed"])
              } else if request.operation == "clock" {
                InputService.encoded(["id": request.id, "success": true, "hostUptimeNanoseconds": received])
              } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { input.handle(request, received: received) } }
              }
            let sent = response.withUnsafeBytes { raw -> Bool in
              var offset = 0
              while offset < raw.count {
                let count = Darwin.send(client, raw.baseAddress! + offset, raw.count - offset, 0)
                if count <= 0 { return false }
                offset += count
              }
              return true
            }
            if !sent { return }
          }
        }
      }
    }
  }
}

// MARK: - Main

@main
private enum Main {
  @MainActor
  static func main() {
    guard CommandLine.arguments.count == 6 else {
      FileHandle.standardError
        .write(Data("HostMouseRelay viewport.json bind-ipv4 allowed-peer-ipv4 private-config.json log-directory\n".utf8))
      exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
      do {
        let viewport = try JSONDecoder().decode(
          Viewport.self,
          from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        )
        let service = try await InputService(
          viewport: viewport,
          peer: CommandLine.arguments[3],
          logDirectory: URL(fileURLWithPath: CommandLine.arguments[5])
        )
        try SocketService.listen(
          host: CommandLine.arguments[2],
          peer: CommandLine.arguments[3],
          token: UUID().uuidString,
          configurationURL: URL(fileURLWithPath: CommandLine.arguments[4]),
          input: service
        )
        FileHandle.standardOutput.write(Data("Host input service ready: \(service.sessionID)\n".utf8))
      } catch {
        FileHandle.standardError.write(Data("HostMouseRelay: \(error)\n".utf8))
        exit(1)
      }
    }
    app.run()
  }
}
