// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import AVKit

// MARK: - SourceCanvas

/// A separate native source application. It never talks to SwiftyCrow, OCR,
/// translation, or the clipboard. Its only job is to show original source pixels.
@MainActor
final class SourceCanvas: NSView {

  // MARK: Lifecycle

  init(scene: String, assets: URL, textAssets: URL) {
    self.scene = scene
    let textURL = textAssets.appendingPathComponent("source-text.json")
    sourceStrings = FileManager.default.fileExists(atPath: textURL.path)
      ? try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: textURL)) : nil
    background = scene == "game" ? NSImage(contentsOf: assets.appendingPathComponent("glass-observatory.png")) : nil
    super.init(frame: .zero)
    if scene == "game" { precondition(background != nil, "Missing original game background") }
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityIdentifier("source-canvas")
    setAccessibilityLabel("Original source canvas")
  }

  required init?(coder _: NSCoder) {
    fatalError("Not supported")
  }

  // MARK: Internal

  let scene: String
  let sourceStrings: [String: String]?
  let background: NSImage?
  var index = 0

  override var isFlipped: Bool {
    true
  }

  override var isOpaque: Bool {
    true
  }

  func ink(_ hex: UInt32) -> NSColor {
    NSColor(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
  }

  func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: UInt32, radius: CGFloat = 0) {
    ink(color).setFill()
    NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius).fill()
  }

  func words(
    _ value: String,
    _ x: CGFloat,
    _ y: CGFloat,
    _ w: CGFloat,
    _ h: CGFloat,
    _ size: CGFloat,
    _ color: UInt32,
    bold: Bool = false,
    mono: Bool = false
  ) {
    let p = NSMutableParagraphStyle()
    p.lineSpacing = 12
    let font = mono
      ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
      : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    let authored: String
    if let sourceStrings {
      guard let text = sourceStrings[value] else { preconditionFailure("Missing authored source text: \(value)") }
      authored = text
    } else { authored = value }
    (authored as NSString).draw(
      in: CGRect(x: x, y: y, width: w, height: h),
      withAttributes: [.font: font, .foregroundColor: ink(color), .paragraphStyle: p]
    )
  }

  override func draw(_: NSRect) {
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.scaleBy(x: bounds.width / 1600, y: bounds.height / 1000)
    if scene == "game" { drawGame() } else { drawDepartures() }
    context.restoreGState()
  }

  func drawGame() {
    background!.draw(
      in: CGRect(x: 0, y: 0, width: 1600, height: 1000),
      from: .zero,
      operation: .copy,
      fraction: 1,
      respectFlipped: true,
      hints: nil
    )
    box(90, 740, 1420, 210, 0x101C29, radius: 18)
    box(90, 740, 8, 210, 0xDFBE72, radius: 4)
    words("ASTRONOMER", 125, 758, 1200, 52, 27, 0xE8C977, bold: true)
    let dialogue = index == 0
      ? "The bridge is closed after sunset.\nTake the tunnel beneath the observatory."
      : "You will need the brass key.\nLook for it beside the old telescope."
    words(dialogue, 125, 817, 1340, 125, 42, 0xF4F0DF)
    setAccessibilityValue("game dialogue \(index + 1)")
  }

  func drawDepartures() {
    box(0, 0, 1600, 1000, 0x0B1826)
    box(0, 0, 1600, 182, 0x142C3D)
    words("NORTH HARBOR", 70, 45, 1120, 85, 58, 0xFFFFFF, bold: true)
    words("DEPARTURES", 70, 123, 1100, 48, 27, 0x73BDD0, bold: true)
    words("12:40", 1265, 61, 265, 85, 55, 0xD5E7EB, mono: true)
    words("TIME", 75, 237, 220, 55, 28, 0x78A1B0, bold: true)
    words("DESTINATION", 380, 237, 820, 55, 28, 0x78A1B0, bold: true)
    words("PIER", 1310, 237, 230, 55, 28, 0x78A1B0, bold: true)
    for (i, row) in [
      ["13:00", "LIGHTHOUSE ISLAND", index == 0 ? "EAST" : "WEST"],
      ["13:20", "NORTH BEACH", "NORTH"],
      ["14:00", "OLD TOWN", "EAST"],
    ].enumerated() {
      let y = CGFloat(325 + i * 145)
      box(58, y - 8, 1484, 125, i == 0 ? 0x203F50 : 0x112637, radius: 12)
      words(row[0], 78, y + 21, 250, 80, 47, 0xE8CF87, mono: true)
      words(row[1], 380, y + 21, 875, 80, 46, 0xF3F6F4, bold: true)
      words(row[2], 1310, y + 25, 215, 74, 36, 0xBCE4DB, bold: true)
    }
    box(58, 802, 1484, 143, index == 0 ? 0x203A48 : 0x493D25, radius: 14)
    words(index == 0 ? "HARBOR NOTICE" : "BOARDING UPDATE", 83, 820, 1380, 50, 25, index == 0 ? 0x86BACA : 0xF0CB77, bold: true)
    words(
      index == 0 ? "The lighthouse ferry is boarding at the east pier." : "Boarding has moved to the west pier.",
      83,
      872,
      1400,
      65,
      39,
      0xFFFFFF
    )
    setAccessibilityValue("departures notice \(index + 1)")
  }
}

// MARK: - DemoScenesDelegate

@MainActor
final class DemoScenesDelegate: NSObject, NSApplicationDelegate {

  // MARK: Lifecycle

  init(scene: String, assets: URL, sourceLanguage: String) {
    self.scene = scene
    self.assets = assets
    switch sourceLanguage {
    case "en-US": textAssets = assets
    case "ko-KR": textAssets = assets.appendingPathComponent("LocalizedSources/ko")
    default: preconditionFailure("Unsupported authored source language: \(sourceLanguage)")
    }
  }

  // MARK: Internal

  let scene: String
  let assets: URL
  let textAssets: URL
  var window: NSWindow!
  var canvas: SourceCanvas?
  var player: AVPlayer?
  var playbackObserver: Any?
  var startedAt: TimeInterval?
  var elapsed: TimeInterval = 0
  var timer: Timer?
  var playButton: NSButton!
  var stateLabel: NSTextField!

  func applicationDidFinishLaunching(_: Notification) {
    let title = [
      "departures": "North Harbor — Departures",
      "science": "Field Notes — Light and Shadow",
      "game": "The Glass Observatory",
    ][scene]!
    window = NSWindow(
      contentRect: CGRect(x: 100, y: 100, width: 1600, height: 1060),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.identifier = NSUserInterfaceItemIdentifier("source-window")
    window.minSize = CGSize(width: 800, height: 560)
    window.contentAspectRatio = CGSize(width: 1600, height: 1060)
    let root = window.contentView!
    let content: NSView
    if scene == "science" {
      let url = textAssets.appendingPathComponent("science-light.mp4")
      precondition(FileManager.default.fileExists(atPath: url.path), "Missing original science video")
      let p = AVPlayer(url: url)
      player = p
      let view = AVPlayerView()
      view.player = p
      view.controlsStyle = .none
      view.videoGravity = .resizeAspect
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.group)
      view.setAccessibilityIdentifier("source-canvas")
      view.setAccessibilityLabel("Original science video")
      content = view
      playbackObserver = p
        .addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateState() }
        }
    } else {
      let view = SourceCanvas(scene: scene, assets: assets, textAssets: textAssets)
      canvas = view
      content = view
    }
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    let bar = NSView()
    bar.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(bar)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      content.topAnchor.constraint(equalTo: root.topAnchor),
      content.bottomAnchor.constraint(equalTo: bar.topAnchor),
      bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      bar.heightAnchor.constraint(equalToConstant: 60),
    ])
    playButton = NSButton(title: scene == "game" ? "Continue" : "Play", target: self, action: #selector(play))
    playButton.setAccessibilityIdentifier(scene == "game" ? "next" : "play")
    let reset = NSButton(title: "Restart", target: self, action: #selector(resetScene))
    reset.setAccessibilityIdentifier("reset")
    stateLabel = NSTextField(labelWithString: "")
    stateLabel.setAccessibilityIdentifier("source-state")
    let stack = NSStackView(views: [playButton, reset, stateLabel])
    stack.spacing = 20
    stack.translatesAutoresizingMaskIntoConstraints = false
    bar.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 24),
      stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
    ])
    timer = Timer
      .scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    updateState()
  }

  @objc
  func play() {
    if scene == "game" { canvas!.index = min(1, canvas!.index + 1)
      canvas!.needsDisplay = true
    } else if let player { if player.rate == 0 { player.play() } else { player.pause() } }
    else if let start = startedAt { elapsed += ProcessInfo.processInfo.systemUptime - start
      startedAt = nil
    } else { startedAt = ProcessInfo.processInfo.systemUptime }
    updateState()
  }

  @objc
  func resetScene() {
    player?.pause()
    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    elapsed = 0
    startedAt = nil
    canvas?.index = 0
    canvas?.needsDisplay = true
    updateState()
  }

  func tick() {
    guard scene == "departures", let start = startedAt else { return }
    let newIndex = elapsed + ProcessInfo.processInfo.systemUptime - start >= 8 ? 1 : 0
    if canvas!.index != newIndex { canvas!.index = newIndex
      canvas!.needsDisplay = true
    }
    updateState()
  }

  func updateState() {
    let running = player.map { $0.rate != 0 } ?? (startedAt != nil)
    let step = player.map { min(2, Int(max(0, $0.currentTime().seconds) / 8)) } ?? canvas?.index ?? 0
    stateLabel.stringValue = "\(running ? "Playing" : "Paused") · \(step + 1)"
    if scene != "game" { playButton.title = running ? "Pause" : "Play" }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
    true
  }
}

// MARK: - DemoScenesMain

@main
struct DemoScenesMain {
  @MainActor
  static func main() {
    let args = CommandLine.arguments
    func option(_ name: String) -> String? {
      guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
      return args[i + 1]
    }
    guard let scene = option("--scene"), ["departures", "science", "game"].contains(scene), let path = option("--fixtures") else {
      fputs("Usage: DemoScenes --scene departures|science|game --fixtures DIRECTORY\n", stderr)
      exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu()
    let item = NSMenuItem()
    menu.addItem(item)
    let submenu = NSMenu()
    submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu
    app.mainMenu = menu
    let delegate = DemoScenesDelegate(scene: scene, assets: URL(fileURLWithPath: path, isDirectory: true), sourceLanguage: option("--source-language") ?? "en-US")
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
