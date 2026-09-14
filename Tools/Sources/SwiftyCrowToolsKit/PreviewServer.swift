// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
#if canImport(System)
import System
#else
import SystemPackage
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - PreviewServer

struct PreviewServer: Sendable {

  let directory: URL
  let workspace: Workspace
  let port: UInt16

  var address: String {
    "http://127.0.0.1:\(port)/"
  }

  var rootHash: String {
    sha(Data(directory.resolvingSymlinksInPath().path.utf8))
  }

  func application() -> some ApplicationProtocol {
    let router = Router()
    let provider = PreviewFileProvider(directory: directory, workspace: workspace)
    router.add(middleware: PreviewHeaders(provider: provider, rootHash: rootHash))
    router.add(middleware: FileMiddleware(fileProvider: provider, searchForIndexHtml: true))
    return Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: Int(port))))
  }

  func start() async throws {
    try require(directory.at("index.html").exists, "index.html is missing in \(directory.path)")
    print("\(address) → \(directory.path)")
    try await application().runService()
  }
}

// MARK: - PreviewFileProvider

/// Resolve symlinks before serving files so the preview remains inside its directory.
private struct PreviewFileProvider: FileProvider {

  // MARK: Lifecycle

  init(directory: URL, workspace _: Workspace) {
    self.directory = directory.resolvingSymlinksInPath()
    directoryPath = Self.resolvedPath(directory)
    filesystem = LocalFileSystem(rootFolder: directory.path, threadPool: .singleton, logger: .init(label: "swiftycrow-preview"))
  }

  // MARK: Internal

  typealias FileIdentifier = String
  typealias FileAttributes = LocalFileSystem.FileAttributes

  let directory: URL
  let directoryPath: String
  let filesystem: LocalFileSystem

  func getFileIdentifier(_ path: String) -> String? {
    let file = directory.at(String(path.drop(while: { $0 == "/" }))).resolvingSymlinksInPath()
    let filePath = Self.resolvedPath(file)
    let prefix = directoryPath == "/" ? "/" : directoryPath + "/"
    guard filePath == directoryPath || filePath.hasPrefix(prefix) else { return nil }
    return filePath
  }

  func getAttributes(id: String) async throws -> FileAttributes? {
    try await filesystem.getAttributes(id: id)
  }

  func loadFile(id: String, context: some RequestContext) async throws -> ResponseBody {
    try await filesystem.loadFile(
      id: id,
      context: context
    )
  }

  func loadFile(
    id: String,
    range: ClosedRange<Int>,
    context: some RequestContext
  ) async throws -> ResponseBody {
    try await filesystem.loadFile(
      id: id,
      range: range,
      context: context
    )
  }

  // MARK: Private

  /// URL equality can distinguish directory hints and trailing separators.
  /// Confinement compares resolved filesystem paths on both Darwin and Linux.
  private static func resolvedPath(_ url: URL) -> String {
    FilePath(url.resolvingSymlinksInPath().path).lexicallyNormalized().string
  }

}

// MARK: - PreviewHeaders

private struct PreviewHeaders: RouterMiddleware {

  // MARK: Internal

  typealias Context = BasicRequestContext

  let provider: PreviewFileProvider
  let rootHash: String

  func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
    guard request.method == .get || request.method == .head else { throw HTTPError(.methodNotAllowed) }
    var head = request.head
    // Hummingbird 2.26 interprets suffix ranges as prefixes and does not reject a
    // start beyond EOF. Normalize to a bounded explicit range before FileMiddleware.
    // Remove this compatibility adapter when upstream passes the preview range tests.
    if
      let range = request.headers[.range], let path = request.uri.path.removingPercentEncoding,
      let file = provider.getFileIdentifier(path), let attributes = try await provider.getAttributes(id: file),
      !attributes.isFolder
    {
      do {
        let bounded = try PreviewRange.resolve(range, size: attributes.size)
        head.headerFields[.range] = "bytes=\(bounded.lowerBound)-\(bounded.upperBound)"
      } catch {
        var response = Response(status: .rangeNotSatisfiable)
        response.headers[.contentRange] = "bytes */\(attributes.size)"
        return identify(response)
      }
    }
    return identify(try await next(Request(head: head, body: request.body), context))
  }

  // MARK: Private

  private func identify(_ value: Response) -> Response {
    var response = value
    response.headers[.init("X-SwiftyCrow-Preview-PID")!] = String(getpid())
    response.headers[.init("X-SwiftyCrow-Preview-Root")!] = rootHash
    response.headers[.cacheControl] = "no-cache"
    return response
  }

}

// MARK: - PreviewRange

enum PreviewRange {
  static func resolve(_ value: String, size: Int) throws -> ClosedRange<Int> {
    guard
      let match = matches(#"^bytes=(\d*)-(\d*)$"#, value).first,
      !match[1].isEmpty || !match[2].isEmpty
    else { throw ToolError("Invalid byte range") }
    let first = Int(match[1])
    let last = Int(match[2])
    try require(match[1].isEmpty || first != nil, "Invalid byte range")
    try require(match[2].isEmpty || last != nil, "Invalid byte range")
    let start = first ?? max(0, size - (last ?? 0))
    let end = first != nil && last != nil ? min(last!, size - 1) : size - 1
    try require(start <= end && start < size, "Invalid byte range")
    return start...end
  }
}
