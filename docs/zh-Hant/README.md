<!-- LANGUAGE-LINKS:START -->
[English](../../README.md) · [한국어](../ko/README.md) · [日本語](../ja/README.md) · [简体中文](../zh-Hans/README.md) · [繁體中文](README.md)
<!-- LANGUAGE-LINKS:END -->

<!--
SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
SPDX-License-Identifier: MPL-2.0 OR AGPL-3.0-only
-->

<a id="swiftycrow"></a>
# SwiftyCrow <img src="../../Resources/Marketing/app-icon.png" align="right" height="128" />

[![最新版本](https://img.shields.io/github/v/release/PangMo5/SwiftyCrow?sort=semver)](https://github.com/PangMo5/SwiftyCrow/releases/latest) [![下載](https://img.shields.io/github/downloads/PangMo5/SwiftyCrow/total)](https://github.com/PangMo5/SwiftyCrow/releases) ![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) [![授權條款：AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](../../LICENSE)

一款完全在本機處理的 macOS 螢幕翻譯 App。

SwiftyCrow 能辨識並翻譯所選螢幕區域或視窗中的文字。擷取靜態圖片，閱讀並運用譯文；也可以使用即時翻譯，持續閱讀不斷變化的內容。辨識與翻譯使用 Mac 上的語言模型，不需要雲端 API 或帳號。

<a id="see-swiftycrow-in-action"></a>
## 看看 SwiftyCrow 如何使用

[![觀看完整閱讀流程](../../web/media/zh-Hant/tour.jpg)](https://swiftycrow.pangmo5.dev/zh-Hant/#demo-tour)

概覽影片展示如何擷取螢幕文字、翻譯並將結果複製到筆記中。下方的功能影片分別示範圖片複製、即時更新、獨立翻譯視窗和直排文字辨識。

<a id="why-swiftycrow"></a>
## 為什麼選擇 SwiftyCrow？

網頁、圖片或 App 中的文字並不總能方便地選取和複製。SwiftyCrow 從螢幕讀取文字，讓你在查看原 App 的同時翻譯。

- **從螢幕翻譯：** 直接選取相關區域，無須先儲存檔案或將文字移入其他 App。
- **選擇合適的模式：** 用擷取翻譯一次螢幕內容，或用即時翻譯持續閱讀變化的文字。
- **運用翻譯結果：** 儲存或複製翻譯後的圖片，也可以只複製原文或譯文。

<a id="features"></a>
## 主要功能

<a id="capture-and-reuse"></a>
### 擷取後用於自己的工作

<a href="https://swiftycrow.pangmo5.dev/zh-Hant/#demo-capture"><img align="right" src="../../web/media/zh-Hant/capture.jpg" width="160" alt="" /></a>

- **區域或視窗：** 拖曳選取螢幕區域，或按**空白鍵**反白並選取整個視窗。
- **擷取圖片翻譯：** 在獨立的結果視窗中閱讀譯文，同時保留圖片及其版面。
- **縮放與符合視窗：** 放大圖片，或使其符合結果視窗大小。100% 時，一個擷取像素對應一個螢幕像素。
- **儲存與複製：** 儲存為 PNG、複製翻譯後的圖片，或將辨識的原文和譯文複製為文字。不論如何縮放或平移，圖片輸出均維持完整擷取畫面的原始解析度。

<br clear="right" />

<a id="follow-changing-content"></a>
### 跟隨畫面變化繼續閱讀

<a href="https://swiftycrow.pangmo5.dev/zh-Hant/#demo-live"><img align="right" src="../../web/media/zh-Hant/live.jpg" width="160" alt="" /></a>

- **持續翻譯：** 選定一次區域或視窗，其中的文字變化時就會重新辨識並翻譯。
- **操作原 App：** 內容區域的點選和捲動會直接傳遞給下方的 App。
- **暫停與繼續：** 使用 **即時** 按鈕暫停或繼續翻譯，使用 **×** 關閉浮動翻譯。
- **記住所選區域：** 無須重新選取，即可顯示或隱藏上次區域的翻譯。隱藏時會停止擷取和翻譯；再次遇到相同文字時可重用先前的譯文。

<br clear="right" />

<a id="keep-the-original-in-view"></a>
#### 對照原文閱讀

<a href="https://swiftycrow.pangmo5.dev/zh-Hant/#demo-compare"><img align="right" src="../../web/media/zh-Hant/compare.jpg" width="160" alt="" /></a>

- **顯示方式：** 在原文上方顯示翻譯，或在旁邊的獨立視窗中閱讀。
- **獨立翻譯視窗：** 在原 App 旁閱讀譯文，不遮擋其內容。文字變化時，同一個翻譯視窗會隨之更新。

<br clear="right" />

<a id="read-images-and-documents"></a>
### 閱讀圖片與文件

<a href="https://swiftycrow.pangmo5.dev/zh-Hant/#demo-layout"><img align="right" src="../../web/media/zh-Hant/layout.jpg" width="160" alt="" /></a>

- **閱讀順序：** 依閱讀順序辨識直排日文、中文和多欄文字。
- **文件結構：** 辨識擷取頁面中的標題、內文、圖片說明和側欄文字。
- **原文文字：** 直接複製辨識出的文字，用於筆記或其他用途，無須手動抄寫。

<br clear="right" />

<a id="languages-and-translation"></a>
### 語言與翻譯

- **Mac 支援的語言：** 可選擇 macOS 支援的原文語言與翻譯語言。翻譯前請下載所需模型。將原文語言設為**自動偵測**，即可逐行辨識混合語言的內容。
- **兩種翻譯方式：** 選擇**快速**以速度優先，或在執行 macOS 26.4 以上版本的支援裝置上選擇**高品質**，使用 Apple Intelligence。

<a id="interface-and-settings"></a>
### 介面與設定

- **選單列控制：** 從選單列啟動擷取或即時翻譯，並在設定中配置快速鍵。
- **啟動與更新：** 設定登入時啟動，以及自動檢查更新。
- **設定檔：** App 內設定與 TOML 設定檔保持同步。

<a id="install"></a>
## 安裝

需要 **macOS 26 或以上版本**。

**Homebrew**（建議）：

```sh
brew install --cask PangMo5/tap/swiftycrow
```

**直接下載：** 從[發布頁面](https://github.com/PangMo5/SwiftyCrow/releases/latest)取得最新的 `.dmg`，開啟後將 App 拖到「應用程式」檔案夾。每個版本也提供對應原始碼封存檔的連結。

首次啟動時，快速設定會引導你允許螢幕錄製、下載語言並完成首次擷取。開啟系統設定前會儲存目前步驟和所選語言，因此即使 macOS 結束並重新開啟 App，也能繼續設定。還可在設定 → 一般 → 權限中查看目前狀態。

<a id="usage"></a>
## 使用方式

1. 在設定（`⌘,`）中選擇**原文語言**與**翻譯語言**。
2. **擷取區域：** 從彈出面板或快速鍵啟動**擷取翻譯**，然後拖曳文字範圍。也可按**空白鍵**反白並點選整個視窗。拖曳預覽的標題區域可移動視窗。使用 `⌘+` / `⌘−` 縮放，點選百分比或按 `⌘0` 符合視窗大小；100% 表示一個圖片像素對應一個螢幕像素。預覽支援 `⌘S` 儲存、`⌘C` 複製圖片、`⌘O` 複製原文、`⌘T` 複製譯文，以及 `Esc` 關閉。儲存和複製始終包含原始解析度的完整圖片，與縮放或平移無關。
3. **使用即時翻譯：** 點選**即時翻譯**按鈕選取區域或視窗，再次點選可選取新區域。旁邊的**顯示浮動翻譯**開關控制所選區域的顯示和隱藏；選取區域前處於停用狀態。使用浮動翻譯中的 **即時** 暫停或繼續，使用 `⌘C` 複製完整譯文，使用 **×** 關閉。
4. **顯示或隱藏翻譯：** **顯示浮動翻譯**開關控制所選區域的翻譯。隱藏時停止擷取和翻譯，再次顯示時在同一區域繼續。

擷取、即時翻譯及儲存、複製操作的快速鍵，可在設定 → 快速鍵中修改。

<a id="troubleshooting"></a>
## 疑難排解

<a id="unable-to-translate-or-a-missing-model-hint"></a>
### 翻譯失敗或提示缺少模型

SwiftyCrow 使用 Apple 的裝置端翻譯框架，需要先安裝對應語言的模型。如果翻譯失敗或提示**語言模型尚未安裝**，通常是因為偵測到的語言模型還未下載。

**安裝翻譯模型：**

1. 開啟**系統設定** → **一般** → **語言與地區**。
2. 向下捲動並選擇**翻譯語言…**。
3. 為原文語言與翻譯語言**分別**點按**下載**。使用**自動偵測**時，請安裝擷取內容中可能出現的所有語言。
4. 重新啟動 SwiftyCrow 後再試。

App 中的**開啟設定**按鈕可直接前往對應設定。不再需要提醒時可選擇**不再顯示**。模型由 macOS 管理並儲存在本機；可在相同面板刪除不用的模型以釋出空間。

詳細資訊請參閱 [docs/LANGUAGE_MODELS.md](LANGUAGE_MODELS.md)。

<a id="configuration"></a>
## 設定

設定儲存在 `~/.config/SwiftyCrow/config.toml`，依 App 的設定頁分為 `[languages]`、`[overlay]`、`[shortcuts]`、`[translation]` 和 `[updates]` 資料表。App 內的修改與手動編輯檔案的變更會保持同步。

所有鍵、預設值與快速鍵語法請查看 [docs/CONFIGURATION.md](CONFIGURATION.md)。

<a id="development"></a>
## 開發

<a id="requirements"></a>
### 環境需求

- Xcode 26.4 或以上版本，包含 Swift 6.3 與 macOS 26.4 或更新的 SDK
- [mise](https://mise.jdx.dev)（透過 `.mise.toml` 管理 Tuist）
- 另行安裝 SwiftFormat，用於原始碼格式化

<a id="building-from-source"></a>
### 從原始碼建置

```sh
export TUIST_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export TUIST_SPARKLE_PUBLIC_ED_KEY=YOUR_SPARKLE_PUBLIC_KEY
mise install               # installs Tuist
tuist install              # resolves SPM dependencies
tuist generate             # generates the Xcode workspace
open SwiftyCrow.xcworkspace
```

Debug 建置使用 Apple Development 簽章。請將 `TUIST_DEVELOPMENT_TEAM` 設為開發憑證所屬的團隊。保持簽章一致，可讓 macOS 在重新建置後繼續保留螢幕錄製授權。將這些值寫入 shell 設定或本機 `.mise.local.toml`：

```toml
[env]
TUIST_DEVELOPMENT_TEAM     = "YOUR_TEAM_ID"
TUIST_SPARKLE_PUBLIC_ED_KEY = "YOUR_SPARKLE_PUBLIC_KEY"
```

`TUIST_SPARKLE_PUBLIC_ED_KEY` 提供產生專案時寫入 `Info.plist` 的公開驗證金鑰。金鑰必須有效，並與更新來源的簽章金鑰相符。使用官方更新來源時，請使用發布版 App `Contents/Info.plist` 中的 `SUPublicEDKey`。分支版本需要自己的更新來源與相符的公開金鑰。

<a id="localization-and-site-previews"></a>
### 在地化與網站預覽

術語與寫作風格請遵循 [docs/LOCALIZATION.md](../LOCALIZATION.md)。App 目錄、文件與網站使用相同的五種語言，每次建置 App 前都會檢查產生檔案與目錄是否一致。

```sh
swift run --package-path Tools swiftycrow-tools check
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools site --output DerivedData/Site
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/Site --port 8085
```

<a id="tech-stack"></a>
### 技術組成

- 由 **Tuist** 產生的工作空間（`Project.swift`、`Tuist/Package.swift`）
- 使用 **TCA**（`swift-composable-architecture`）管理 App 與擷取狀態，透過 `@DependencyClient` 注入相依項目。
- 透過 **swift-sharing** 的 `fileStorage` 方式連接 **swift-toml**。
- 使用 **Magnet** 註冊全域快速鍵，並提供小型自訂快速鍵輸入控制項。
- App 內更新使用 **Sparkle**。
- 使用 **Apple Vision** 辨識文字、**Apple 翻譯**進行翻譯、**ScreenCaptureKit** 擷取螢幕。
- 使用 `.swiftformat` 中的 [Airbnb SwiftFormat](https://github.com/airbnb/swift) 設定統一原始碼格式。

<a id="license"></a>
## 授權條款

[GNU Affero General Public License v3.0 only](../../LICENSE) (`AGPL-3.0-only`). Copyright (C) 2021-2026 PangMo5.

散布修改後的版本時，必須以相同授權條款提供對應的原始碼。第 13 條也要求透過網路使用的修改版向遠端使用者提供對應原始碼。

這份 README 與 `docs/LANGUAGE_MODELS.md` 包含先前以 MPL-2.0 提交的文件貢獻，依檔案中的說明，仍可選擇 [MPL-2.0](https://www.mozilla.org/MPL/2.0/) 或 AGPL-3.0-only 使用。專案於 2021 年採用 MIT 授權條款，2026 年先改為 MPL-2.0，再改為 AGPL-3.0-only。

使用的套件授權條款與確切原始碼修訂記錄在 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) 中。此檔案與授權條款均包含在發布的 App 套件內。
