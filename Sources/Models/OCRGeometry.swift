// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRGeometry

enum OCRGeometry {
  static func isVertical(text: String, topLeft: CGPoint, topRight: CGPoint, imageSize: CGSize, declaredVertical: Bool) -> Bool {
    if declaredVertical { return true }
    let dx = abs(topRight.x - topLeft.x) * imageSize.width
    let dy = abs(topRight.y - topLeft.y) * imageSize.height
    return dy > dx * 2 && OverlayTextFlowResolver.scriptEvidence(in: text).verticalCharacterCount >= 2
  }

  static func alignedBox(_ box: CGRect, angle: CGFloat, aspect: CGFloat) -> CGRect {
    let x = box.midX * aspect
    let y = box.midY
    return CGRect(
      x: (x * cos(angle) + y * sin(angle)) / aspect - box.width / 2,
      y: -x * sin(angle) + y * cos(angle) - box.height / 2,
      width: box.width,
      height: box.height
    )
  }

  static func combinedFrame(_ lines: [OCRResult.Line], angle: CGFloat) -> CGRect {
    let aspect = lines.first?.imageAspectRatio ?? 1
    let projected = lines.map { alignedBox($0.orientedBox ?? $0.boundingBoxNormalized, angle: angle, aspect: aspect) }
    let union = projected.dropFirst().reduce(projected[0]) { $0.union($1) }
    let x = union.midX * aspect
    let y = union.midY
    return CGRect(
      x: (x * cos(angle) - y * sin(angle)) / aspect - union.width / 2,
      y: x * sin(angle) + y * cos(angle) - union.height / 2,
      width: union.width,
      height: union.height
    )
  }
}

extension OCRResult.Line {
  var alignedBox: CGRect {
    guard abs(rotationRadians) > 0.025 else { return orientedBox ?? boundingBoxNormalized }
    return OCRGeometry.alignedBox(orientedBox ?? boundingBoxNormalized, angle: rotationRadians, aspect: imageAspectRatio)
  }
}
