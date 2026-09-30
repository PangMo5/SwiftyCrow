// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - CaptureQualityLanguage

struct CaptureQualityLanguage: Sendable {
  var code: String
  var heading: String
  var labels: [String]
  var body: String
  var note: String
  var rtl = false
}

extension CaptureQualityLanguage {
  static let all: [Self] = [
    .init(
      code: "en",
      heading: "Settings and privacy",
      labels: ["Overview", "Downloads", "Documentation", "Support"],
      body: "Keep the original files. Review the changes before continuing. Do not disconnect the device while an update is running.",
      note: "The price changed from $50 to $15. The backup runs every 15 minutes."
    ),
    .init(
      code: "ko",
      heading: "설정과 개인정보",
      labels: ["개요", "다운로드", "사용 설명서", "지원"],
      body: "원본 파일을 보관하세요. 계속하기 전에 변경 사항을 확인하세요. 업데이트 중에는 기기를 분리하지 마세요.",
      note: "가격이 50달러에서 15달러로 바뀌었습니다. 백업은 15분마다 실행됩니다."
    ),
    .init(
      code: "ja",
      heading: "設定とプライバシー",
      labels: ["概要", "ダウンロード", "ドキュメント", "サポート"],
      body: "元のファイルを保管してください。続行する前に変更内容を確認してください。更新中はデバイスを取り外さないでください。",
      note: "価格は50ドルから15ドルに変わりました。バックアップは15分ごとに実行されます。"
    ),
    .init(
      code: "zh-Hans",
      heading: "设置与隐私",
      labels: ["概览", "下载", "使用文档", "支持"],
      body: "请保留原始文件。继续之前，请检查更改。更新过程中请勿断开设备连接。",
      note: "价格从50美元降至15美元。每15分钟执行一次备份。"
    ),
    .init(
      code: "zh-Hant",
      heading: "設定與隱私",
      labels: ["概覽", "下載", "使用文件", "支援"],
      body: "請保留原始檔案。繼續之前，請檢查變更。更新過程中請勿中斷裝置連線。",
      note: "價格從50美元降至15美元。每15分鐘執行一次備份。"
    ),
    .init(
      code: "ar",
      heading: "الإعدادات والخصوصية",
      labels: ["نظرة عامة", "التنزيلات", "المستندات", "الدعم"],
      body: "احتفظ بالملفات الأصلية. راجع التغييرات قبل المتابعة. لا تفصل الجهاز أثناء التحديث.",
      note: "انخفض السعر من 50 دولارًا إلى 15 دولارًا. يتم النسخ الاحتياطي كل 15 دقيقة.",
      rtl: true
    ),
    .init(
      code: "he",
      heading: "הגדרות ופרטיות",
      labels: ["סקירה", "הורדות", "תיעוד", "תמיכה"],
      body: "שמרו את הקבצים המקוריים. בדקו את השינויים לפני שממשיכים. אין לנתק את המכשיר בזמן העדכון.",
      note: "המחיר ירד מ-50 דולר ל-15 דולר. הגיבוי פועל כל 15 דקות.",
      rtl: true
    ),
    .init(
      code: "fr",
      heading: "Paramètres et confidentialité",
      labels: ["Présentation", "Téléchargements", "Documentation", "Assistance"],
      body: "Conservez les fichiers originaux. Vérifiez les modifications avant de continuer. Ne débranchez pas l’appareil pendant la mise à jour.",
      note: "Le prix est passé de 50 dollars à 15 dollars. La sauvegarde démarre toutes les 15 minutes."
    ),
    .init(
      code: "de",
      heading: "Einstellungen und Datenschutz",
      labels: ["Übersicht", "Downloads", "Dokumentation", "Hilfe"],
      body: "Bewahren Sie die Originaldateien auf. Prüfen Sie die Änderungen, bevor Sie fortfahren. Trennen Sie das Gerät während des Updates nicht.",
      note: "Der Preis ist von 50 auf 15 Dollar gesunken. Die Sicherung wird alle 15 Minuten ausgeführt."
    ),
  ]
}

// MARK: - CaptureQualityStructure

/// Shared authored geometry for fast compositor tests and native source images.
/// Text here is fixture data, not an assertion of model translation accuracy.
enum CaptureQualityStructure: String, CaseIterable, Sendable {
  case navigation
  case columns
  case cards
  case table
  case article
  case dialog

  // MARK: Internal

  struct Block: Sendable {
    enum Role: Sendable { case heading, label, prose, literal }

    var text: String
    var rect: CGRect
    var size: CGFloat
    var role: Role
  }

  func blocks(_ copy: CaptureQualityLanguage) -> [Block] {
    func block(
      _ text: String,
      _ x: CGFloat,
      _ y: CGFloat,
      _ w: CGFloat,
      _ h: CGFloat,
      _ size: CGFloat,
      _ role: Block.Role
    ) -> Block {
      .init(text: text, rect: CGRect(x: x, y: y, width: w, height: h), size: size, role: role)
    }
    let title = block(copy.heading, 40, 25, 1100, 90, 36, .heading)
    switch self {
    case .navigation:
      return [title] + copy.labels.enumerated().map { i, label in
        block(label, 40 + CGFloat(copy.rtl ? 3 - i : i) * 290, 150, 260, 80, 24, .label)
      } + [
        block(copy.body, 40, 270, 800, 210, 26, .prose),
        block(copy.note, 40, 510, 800, 140, 23, .prose),
      ]

    case .columns:
      return [
        title,
        block(copy.body, 40, 160, 500, 280, 25, .prose),
        block(copy.note, 620, 160, 520, 280, 25, .prose),
        block(copy.labels[0], 40, 490, 500, 80, 25, .label),
        block(copy.labels[1], 620, 490, 520, 80, 25, .label),
      ]

    case .cards:
      return [
        title,
        block(copy.labels[0], 60, 150, 440, 80, 28, .label),
        block(copy.body, 60, 250, 440, 300, 24, .prose),
        block(copy.labels[1], 660, 150, 440, 80, 28, .label),
        block(copy.note, 660, 250, 440, 300, 24, .prose),
      ]

    case .table:
      return [title] + (0..<4).flatMap { i in [
        block(copy.labels[i], 55, 160 + CGFloat(i) * 115, 410, 90, 24, .label),
        block(
          ["README.md", "v3.2.1", "12:30", "https://example.com/a"][i],
          640,
          160 + CGFloat(i) * 115,
          500,
          90,
          23,
          .literal
        ),
      ] }

    case .article:
      return [
        title,
        block(copy.body + " " + copy.note, 50, 160, 760, 380, 25, .prose),
        block("git status --short", 50, 590, 760, 65, 24, .literal),
        block(copy.labels[1], 870, 590, 270, 65, 24, .label),
      ]

    case .dialog:
      return [
        block(copy.heading, 250, 110, 700, 100, 32, .heading),
        block(copy.body, 250, 250, 700, 250, 26, .prose),
        block(copy.labels[0], 260, 550, 280, 80, 24, .label),
        block(copy.labels[3], 660, 550, 280, 80, 24, .label),
      ]
    }
  }
}
