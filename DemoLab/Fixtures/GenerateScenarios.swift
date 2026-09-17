// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText

// Original source documents. All text is rasterized before SwiftyCrow sees it.
let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
func option(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[index + 1]
}
let destination = option("--output").map { URL(fileURLWithPath: $0) } ?? sourceDirectory
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let magazineName = option("--magazine-name") ?? "japanese-magazine.png"
let selected = Set((option("--images") ?? "travel-leaflet.png,camera-manual.png,japanese-magazine.png").split(separator: ",").map(String.init))
let sourceLocale = option("--source-language")
let sourceStrings: [String: String]? = try option("--text-catalog").map {
  try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
}
func sourceText(_ value: String) -> String {
  guard let sourceStrings else { return value }
  guard let localized = sourceStrings[value] else { fatalError("Missing authored source text: \(value)") }
  return localized
}
let size = CGSize(width: 1800, height: 1200)
func color(_ hex: UInt32) -> NSColor {
  NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
  CGRect(x: x, y: size.height - y - h, width: w, height: h)
}

func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, radius: CGFloat = 0) {
  color(hex).setFill()
  NSBezierPath(roundedRect: rect(x, y, w, h), xRadius: radius, yRadius: radius).fill()
}

func line(_ points: [CGPoint], _ hex: UInt32, width: CGFloat = 4) {
  let p = NSBezierPath()
  p.lineWidth = width
  p.lineCapStyle = .round
  for (i, v) in points.enumerated() {
    let pt = CGPoint(x: v.x, y: size.height - v.y)
    if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
  }
  color(hex).setStroke()
  p.stroke()
}

func text(
  _ value: String,
  _ x: CGFloat,
  _ y: CGFloat,
  _ w: CGFloat,
  _ h: CGFloat,
  _ fontSize: CGFloat,
  _ hex: UInt32 = 0x182C3A,
  bold: Bool = false,
  serif: Bool = false
) {
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineSpacing = 12
  let font = serif
    ? NSFont(name: sourceLocale == "zh-Hant" ? "PingFang TC" : "Hiragino Mincho ProN", size: fontSize)!
    : NSFont.systemFont(ofSize: fontSize, weight: bold ? .bold : .regular)
  (sourceText(value) as NSString).draw(
    in: rect(x, y, w, h),
    withAttributes: [.font: font, .foregroundColor: color(hex), .paragraphStyle: paragraph]
  )
}

func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32) {
  color(hex).setFill()
  NSBezierPath(ovalIn: rect(x, y, w, h)).fill()
}

func make(_ name: String, draw: () -> Void) throws {
  guard selected.contains(name) else { return }
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  fill(0, 0, size.width, size.height, 0xFAF7EE)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
  print(name)
}

try make("travel-leaflet.png") {
  fill(0, 0, 720, 1200, 0x184D55)
  text("A DAY BY\nTHE SEA", 70, 70, 620, 250, 86, 0xFCF5DE, bold: true)
  text("NORTH HARBOR", 76, 352, 620, 60, 31, 0xF7CA77, bold: true)
  // Illustrated map, distinct from the source document and game art.
  fill(60, 470, 600, 620, 0xCBE6E4, radius: 24)
  let coast = NSBezierPath()
  coast.move(to: CGPoint(x: 60, y: 1200 - 470))
  coast.line(to: CGPoint(x: 440, y: 1200 - 470))
  coast.curve(
    to: CGPoint(x: 210, y: 1200 - 1090),
    controlPoint1: CGPoint(x: 270, y: 1200 - 640),
    controlPoint2: CGPoint(x: 520, y: 1200 - 880)
  )
  coast.line(to: CGPoint(x: 60, y: 1200 - 1090))
  coast.close()
  color(0xECDEA9).setFill()
  coast.fill()
  line([CGPoint(x: 190, y: 940), CGPoint(x: 250, y: 800), CGPoint(x: 310, y: 650), CGPoint(x: 400, y: 540)], 0xC67B56, width: 10)
  for (x, y) in [(190.0, 940.0), (250.0, 800.0), (310.0, 650.0)] { ellipse(x - 16, y - 16, 32, 32, 0x184D55)
    ellipse(x - 7, y - 7, 14, 14, 0xFCF5DE)
  }
  fill(395, 494, 38, 95, 0xFCF5DE)
  fill(386, 486, 56, 18, 0xC66748)
  fill(401, 520, 26, 15, 0x184D55)
  text("WALK  /  FERRY  /  EXPLORE", 810, 85, 900, 55, 29, 0xB25E39, bold: true)
  text("Your harbor afternoon", 805, 180, 900, 180, 74, bold: true)
  fill(815, 382, 860, 3, 0xD9CCB1)
  text("PLAN YOUR VISIT", 815, 432, 850, 70, 37, 0x184D55, bold: true)
  text(
    "The lighthouse opens at noon.\nTake the ferry from the east pier.\nThe last return boat leaves at six.",
    815,
    535,
    880,
    310,
    44
  )
  fill(805, 917, 900, 180, 0xF0E6CE, radius: 20)
  text("Before you leave", 835, 942, 820, 55, 33, 0x184D55, bold: true)
  text("Check the harbor departure board.", 835, 1008, 820, 65, 37)
}

try make("camera-manual.png") {
  fill(0, 0, 1800, 210, 0x173749)
  text("FIELD CAMERA", 70, 45, 1100, 100, 70, 0xFFFFFF, bold: true)
  text("QUICK START   /   03", 1260, 90, 480, 65, 30, 0xAFD3DE)
  // Technical line drawing and callouts retain meaningful visual context.
  fill(75, 300, 740, 600, 0xE4EDF0, radius: 24)
  fill(195, 470, 485, 290, 0x5B7180, radius: 36)
  fill(275, 420, 155, 85, 0x5B7180, radius: 15)
  fill(545, 430, 68, 40, 0x213847, radius: 8)
  ellipse(302, 485, 260, 260, 0x263E4B)
  ellipse(338, 521, 188, 188, 0xABC6CB)
  ellipse(369, 552, 126, 126, 0x375866)
  fill(220, 495, 65, 35, 0xC8DDE0, radius: 6)
  line([CGPoint(x: 650, y: 720), CGPoint(x: 705, y: 800), CGPoint(x: 730, y: 800)], 0xC26832, width: 5)
  line([CGPoint(x: 580, y: 445), CGPoint(x: 650, y: 355), CGPoint(x: 725, y: 355)], 0xC26832, width: 5)
  text("POWER BUTTON", 420, 300, 340, 60, 27, 0xA24E24, bold: true)
  text("BATTERY", 410, 814, 300, 60, 31, 0xA24E24, bold: true)
  text("01   Insert the battery", 900, 285, 820, 95, 48, bold: true)
  text("Open the cover at the bottom.\nSlide the battery in until it clicks.", 900, 405, 820, 180, 39)
  text("02   Turn on your camera", 900, 650, 820, 95, 48, bold: true)
  text("Hold the power button for two seconds.\nKeep the lens cap off while shooting.", 900, 770, 820, 180, 39)
  fill(75, 990, 1650, 135, 0xF1D6B6, radius: 18)
  text("CAUTION", 105, 1033, 240, 70, 32, 0x91431E, bold: true)
  text("Do not remove the battery while the light is flashing.", 380, 1025, 1300, 90, 37, 0x62391D)
}

let verticalBody = "雨上がりの町を歩くと、古い本屋の窓に明かりが見えた。店主は温かいお茶を用意して、旅の話を聞いてくれた。帰り道には川沿いの橋を渡った。静かな水面に夕方の空が映っていた。橋の向こうには小さな喫茶店がある。窓際の席で地図を広げ、次に歩く道を決めた。急がずに歩くと、いつもの町にも新しい発見がある。"
try make(magazineName) {
  text("町を歩く", sourceLocale == "zh-Hant" ? 1410 : 80, 45, sourceLocale == "zh-Hant" ? 350 : 900, 120, 78, 0x263A38, bold: true, serif: true)
  text("週末の小さな旅", sourceLocale == "zh-Hant" ? 600 : 1120, 100, 600, 70, 37, 0x7F4936, serif: true)
  fill(80, 190, 1640, 3, 0x8D8C72)
  // Original editorial photography sits beside independent horizontal and vertical text blocks.
  guard let photograph = NSImage(contentsOf: sourceDirectory.appendingPathComponent("riverside-bookshop.png")) else {
    fatalError("Missing original riverside bookshop photograph")
  }
  photograph.draw(in: rect(80, 250, 735, 490))
  text("川沿いに残る、古い本屋のある風景。", 85, 765, 740, 110, 33, 0x5A6E62, serif: true)
  fill(80, 948, 735, 162, 0xE9E3D3, radius: 12)
  text("散歩のメモ", 108, 969, 680, 60, 35, 0x7F4936, bold: true)
  text("駅から川まで、ゆっくり十五分。", 108, 1030, 680, 65, 33, serif: true)
  let paragraph = NSMutableParagraphStyle()
  paragraph.lineSpacing = 22
  let value = NSAttributedString(
    string: sourceText(verticalBody),
    attributes: [
      .font: NSFont(name: sourceLocale == "zh-Hant" ? "PingFang TC" : "Hiragino Mincho ProN", size: sourceLocale == "zh-Hant" ? 46 : 42)!,
      .foregroundColor: color(0x263A38),
      .verticalGlyphForm: true,
      .paragraphStyle: paragraph,
    ]
  )
  let setter = CTFramesetterCreateWithAttributedString(value)
  let frame = CTFramesetterCreateFrame(
    setter,
    CFRange(location: 0, length: 0),
    CGPath(rect: rect(930, 265, 775, 800), transform: nil),
    [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
  )
  let range = CTFrameGetVisibleStringRange(frame)
  precondition(range.length == value.length, "Vertical article must fit completely")
  let context = NSGraphicsContext.current!.cgContext
  context.textMatrix = .identity
  CTFrameDraw(frame, context)
  text("文と写真：編集部", 1370, 1120, 350, 55, 27, 0x7F4936)
}

let evidence: [String: Any] = [
  "verticalBody": selected.contains(magazineName) ? sourceText(verticalBody) : "",
  "sourceLanguages": Dictionary(uniqueKeysWithValues: selected.map { ($0, sourceLocale ?? ($0 == "japanese-magazine.png" ? "ja-JP" : "en-US")) }),
  "note": "Original source material; no translated text is present.",
]
try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
  .write(to: destination.appendingPathComponent("scenario-content.json"))
