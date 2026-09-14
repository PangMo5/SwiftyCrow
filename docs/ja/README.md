<!-- LANGUAGE-LINKS:START -->
[English](../../README.md) · [한국어](../ko/README.md) · [日本語](README.md) · [简体中文](../zh-Hans/README.md) · [繁體中文](../zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

<!--
SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
SPDX-License-Identifier: MPL-2.0 OR AGPL-3.0-only
-->

<a id="swiftycrow"></a>
# SwiftyCrow <img src="../../Resources/Marketing/app-icon.png" align="right" height="128" />

[![最新リリース](https://img.shields.io/github/v/release/PangMo5/SwiftyCrow?sort=semver)](https://github.com/PangMo5/SwiftyCrow/releases/latest) [![ダウンロード](https://img.shields.io/github/downloads/PangMo5/SwiftyCrow/total)](https://github.com/PangMo5/SwiftyCrow/releases) ![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) [![ライセンス: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](../../LICENSE)

すべての処理をMac上で行う画面翻訳アプリです。[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)で画面の任意の範囲をキャプチャし、[Vision](https://developer.apple.com/documentation/vision)で文字を読み取り、[Apple翻訳](https://developer.apple.com/documentation/translation)で翻訳します。クラウドAPI、APIキー、利用回数の制限はありません。

<a id="see-swiftycrow-in-action"></a>
## SwiftyCrow の使い方

[![一連の読書の流れを見る](../../web/media/ja/tour.jpg)](https://swiftycrow.pangmo5.dev/ja/#demo-tour)

港への旅を準備します。観光案内を翻訳してメモに移し、変わる出発案内をライブ翻訳で確認。機能別の動画では、図入りの説明書、動画の字幕、縦書きの日本語雑誌、別ウインドウで読むゲームの会話を紹介します。オリジナルのサンプルを実際の開発版で韓国語に翻訳し、アプリはこのガイドと同じ言語で実行しています。

<a id="features"></a>
## 主な機能

このREADMEは未リリースの変更を含む`main`を基準にしています。各リリースで使える機能は[変更履歴](CHANGELOG.md)をご確認ください。

<a id="capture-and-reuse"></a>
### キャプチャした内容を活用

<img align="right" src="../../web/media/ja/capture.jpg" width="200" alt="" />

[使い方を見る](https://swiftycrow.pangmo5.dev/ja/#demo-capture)

- **範囲をキャプチャ：** 画面の任意の範囲をドラッグするか、**Space**を押してmacOSのスクリーンショットツールのようにウインドウ全体を選べます。結果は原文に訳文を重ねた別ウインドウで開きます。画像の保存・コピーや、原文・訳文のコピーもできます。

<br clear="right" />

<a id="follow-changing-content"></a>
### 変わる内容を読み続ける

<img align="right" src="../../web/media/ja/live.jpg" width="200" alt="" />

[使い方を見る](https://swiftycrow.pangmo5.dev/ja/#demo-live)

- **ライブ翻訳：** 同じ方法で対象を選ぶと、内容の変化に合わせて翻訳します。本文範囲のクリックやスクロールは背後のアプリに届きます。**ライブ**ボタンで一時停止・再開し、**×**で閉じられます。訳文を**原文に重ねて表示**するか、範囲の枠だけを残して**別のウインドウ**で読むこともできます。
- **範囲を決めて必要なときに翻訳：** 前回の範囲を記憶するので、**ライブ翻訳を表示／非表示**で同じ場所の翻訳を切り替えられます。ゲームのパネルなど、位置が固定された情報をときどき読む場合に便利です。非表示にすると、再表示するまでキャプチャと翻訳をすべて停止します。
- **ライブ翻訳を再利用：** 同じ文章に戻ったときは、以前の翻訳結果を再利用します。

<br clear="right" />

<a id="read-images-and-documents"></a>
### 画像や文書を読む

<img align="right" src="../../web/media/ja/layout.jpg" width="200" alt="" />

[使い方を見る](https://swiftycrow.pangmo5.dev/ja/#demo-layout)

- **文書構造を認識：** 縦書きの日本語・中国語や段組みの文章を読む順序に沿って認識します。訳文は翻訳先の言語に合った方向で表示します。
- **Macが対応する言語：** macOSが対応する原文・翻訳先の言語を選べます。翻訳前に必要なモデルをダウンロードしてください。原文を**自動検出**にすると、複数の言語が混在する画面でも行ごとに検出します。
- **2つの翻訳方式：** 速さを優先するなら**速度優先**、対応デバイスのmacOS 26.4以降でApple Intelligenceを使うなら**品質優先**を選べます。

<br clear="right" />

<a id="keep-the-original-in-view"></a>
### 原文も見ながら読む

<img align="right" src="../../web/media/ja/compare.jpg" width="200" alt="" />

[使い方を見る](https://swiftycrow.pangmo5.dev/ja/#demo-compare)

- **読み方を選ぶ：** 原文に訳文を重ねるか、絵を隠さず別ウインドウで読めます。翻訳をいったん非表示にしても、範囲を選び直さず同じ場所で再開できます。
- **メニューバーから操作：** メニューバーのアイコンから操作パネルを開くか、`⌘,`で設定を開けます。
- **ショートカットを設定：** 設定 → ショートカットで、キャプチャ、ライブ翻訳、前回の範囲の表示・非表示、一時停止・再開、表示方法、保存・コピーのキーを変更できます。
- **ログイン時に起動：** ログインするとSwiftyCrowが自動で起動します。
- **設定ファイルを直接編集：** アプリ内の設定と同期するテキストファイルを直接編集できます。

<br clear="right" />

<a id="install"></a>
## インストール

**macOS 26以降**が必要です。

**Homebrew**（推奨）：

```sh
brew install --cask PangMo5/tap/swiftycrow
```

**直接ダウンロード：** [リリースページ](https://github.com/PangMo5/SwiftyCrow/releases/latest)から最新の`.dmg`をダウンロードして開き、アプリをアプリケーションフォルダに移動してください。各リリースには、そのバージョンに対応するソースアーカイブへのリンクもあります。

初回起動時は、システム設定 → プライバシーとセキュリティで**画面収録**を許可してから、アプリを再起動してください。その後のアップデートはアプリから確認できます。

<a id="usage"></a>
## 使い方

1. 設定（`⌘,`）で**原文の言語**と**翻訳先の言語**を選んでください。
2. **範囲をキャプチャ：** 操作パネルかショートカットから**範囲をキャプチャ**を開始し、文章の上をドラッグしてください。**Space**を押すとウインドウ全体を選べます。結果ウインドウはタイトル部分をドラッグして移動できます。`⌘+` / `⌘−`で拡大・縮小し、倍率をクリックするか`⌘0`でウインドウに合わせます。100%では画像の1ピクセルが画面の1ピクセルに対応します。`⌘S`で保存、`⌘C`で画像をコピー、`⌘O`で原文をコピー、`⌘T`で訳文をコピー、`Esc`で閉じます。保存・コピーには倍率や表示位置に関係なく、元の解像度で画像全体が含まれます。
3. **ライブ翻訳：** メニューバーまたはショートカットから**ライブ翻訳…**を開始し、範囲をドラッグするか**Space**でウインドウを選んでください。**ライブ**ボタンで一時停止・再開し、`⌘C`で訳文全体をコピー、**×**で閉じられます。
4. **同じ範囲を再利用：** 範囲を一度決めると、**ライブ翻訳を表示／非表示**で同じ場所の表示を切り替えられます。非表示にするとキャプチャと翻訳をすべて停止します。

キャプチャ、ライブ翻訳、保存・コピーのショートカットは、設定 → ショートカットで変更できます。

<a id="troubleshooting"></a>
## トラブルシューティング

<a id="unable-to-translate-or-a-missing-model-hint"></a>
### 翻訳エラーやモデル未インストールの案内

SwiftyCrowは、翻訳する言語のモデルが必要なAppleのオンデバイス翻訳を使っています。翻訳に失敗したり、**言語モデルがインストールされていないという案内**が表示された場合は、検出した言語のモデルがまだダウンロードされていない可能性があります。

**翻訳モデルをインストールするには：**

1. **システム設定** → **一般** → **言語と地域**を開いてください。
2. 下にスクロールして**翻訳言語…**を選んでください。
3. 原文と翻訳先の**両方**の言語で**ダウンロード**を押してください。原文が**自動検出**の場合は、キャプチャに含まれそうな言語をすべてインストールしてください。
4. SwiftyCrowを再起動して、もう一度お試しください。

アプリの**設定を開く**ボタンから該当する設定に移動できます。案内が不要になったら**今後表示しない**を選べます。モデルはmacOSが管理し、Mac内に保存されます。同じ設定から使わないモデルを削除して空き容量を増やせます。

詳しくは[docs/LANGUAGE_MODELS.md](LANGUAGE_MODELS.md)をご覧ください。

<a id="configuration"></a>
## 設定

設定は`~/.config/SwiftyCrow/config.toml`に保存されます。アプリの設定タブに対応する`[languages]`、`[overlay]`、`[shortcuts]`、`[translation]`、`[updates]`のテーブルに分かれ、アプリ内の変更とファイルの直接編集が相互に同期します。

すべてのキー、初期値、ショートカットの書式は[docs/CONFIGURATION.md](CONFIGURATION.md)で確認できます。

<a id="development"></a>
## 開発

<a id="requirements"></a>
### 必要な環境

- Swift 6.3とmacOS 26.4 SDK以降を含むXcode 26.4以降
- [mise](https://mise.jdx.dev)（`.mise.toml`でTuistを管理）
- ソースコードの書式を整えるSwiftFormatを別途インストール

<a id="building-from-source"></a>
### ソースからビルド

```sh
export TUIST_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export TUIST_SPARKLE_PUBLIC_ED_KEY=YOUR_SPARKLE_PUBLIC_KEY
mise install               # installs Tuist
tuist install              # resolves SPM dependencies
tuist generate             # generates the Xcode workspace
open SwiftyCrow.xcworkspace
```

DebugビルドはApple Development証明書で署名します。`TUIST_DEVELOPMENT_TEAM`には開発証明書に対応するチームを指定してください。同じ署名を使い続けると、再ビルド後もmacOSが画面収録の許可を維持できます。値はシェルのプロファイルかローカルの`.mise.local.toml`に保存してください。

```toml
[env]
TUIST_DEVELOPMENT_TEAM     = "YOUR_TEAM_ID"
TUIST_SPARKLE_PUBLIC_ED_KEY = "YOUR_SPARKLE_PUBLIC_KEY"
```

`TUIST_SPARKLE_PUBLIC_ED_KEY`は、プロジェクト生成時に`Info.plist`へ埋め込む公開検証キーです。有効なキーで、更新フィードの署名キーと一致する必要があります。公式フィードを使う場合は、リリース済みアプリの`Contents/Info.plist`にある`SUPublicEDKey`を使ってください。フォークには独自のフィードと対応する公開キーが必要です。

<a id="localization-and-site-previews"></a>
### ローカライズとサイトのプレビュー

用語と文体は[docs/LOCALIZATION.md](../LOCALIZATION.md)に従ってください。アプリのカタログ、文書、ウェブサイトは同じ5言語を使います。アプリのビルド前に、生成した言語ファイルとカタログの一致を確認します。

```sh
swift run --package-path Tools swiftycrow-tools check
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools site --output DerivedData/Site
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/Site --port 8085
```

<a id="tech-stack"></a>
### 技術構成

- **Tuist**で生成するワークスペース（`Project.swift`、`Tuist/Package.swift`）
- アプリとキャプチャの状態は**TCA**（`swift-composable-architecture`）で管理し、依存関係は`@DependencyClient`で接続します。
- **swift-sharing**の`fileStorage`を**swift-toml**に接続しています。
- グローバルショートカットの登録には**Magnet**を使い、小さな独自の記録欄を用意しています。
- アプリ内の更新には**Sparkle**を使います。
- 文字認識には**Apple Vision**、翻訳には**Apple翻訳**、キャプチャには**ScreenCaptureKit**を使います。
- `.swiftformat`にある[Airbnb SwiftFormat](https://github.com/airbnb/swift)設定でソースコードの書式を統一します。

<a id="license"></a>
## ライセンス

[GNU Affero General Public License v3.0 only](../../LICENSE) (`AGPL-3.0-only`). Copyright (C) 2021-2026 PangMo5.

変更したバージョンを配布する場合は、対応するソースコードを同じライセンスで提供する必要があります。第13条では、ネットワーク経由で使われる変更版について、遠隔の利用者にも対応するソースコードを提供することを求めています。

このREADMEと`docs/LANGUAGE_MODELS.md`には、MPL-2.0で提供された以前の文書の寄稿が含まれています。各ファイルの表示どおり、[MPL-2.0](https://www.mozilla.org/MPL/2.0/)またはAGPL-3.0-onlyのどちらかで利用できます。プロジェクトは2021年にMITライセンスで始まり、2026年にMPL-2.0を経てAGPL-3.0-onlyへ移行しました。

利用しているパッケージのライセンスと正確なソースリビジョンは[THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)に記録しています。このファイルとライセンスは配布アプリにも含まれます。
