<!-- LANGUAGE-LINKS:START -->
[English](../../README.md) · [한국어](../ko/README.md) · [日本語](../ja/README.md) · [简体中文](README.md) · [繁體中文](../zh-Hant/README.md)
<!-- LANGUAGE-LINKS:END -->

<!--
SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
SPDX-License-Identifier: MPL-2.0 OR AGPL-3.0-only
-->

<a id="swiftycrow"></a>
# SwiftyCrow <img src="../../Resources/Marketing/app-icon.png" align="right" height="128" />

[![最新版本](https://img.shields.io/github/v/release/PangMo5/SwiftyCrow?sort=semver)](https://github.com/PangMo5/SwiftyCrow/releases/latest) [![下载](https://img.shields.io/github/downloads/PangMo5/SwiftyCrow/total)](https://github.com/PangMo5/SwiftyCrow/releases) ![macOS 26+](https://img.shields.io/badge/macOS-26%2B-blue) [![许可证：AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-blue.svg)](../../LICENSE)

一款完全在 Mac 上处理的屏幕翻译应用。通过 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) 截取任意屏幕区域，用 [Vision](https://developer.apple.com/documentation/vision) 识别文字，再通过 [Apple 翻译](https://developer.apple.com/documentation/translation)进行翻译。无需云端 API、密钥或配额。

<a id="see-swiftycrow-in-action"></a>
## 看看 SwiftyCrow 如何使用

[![观看完整阅读流程](../../web/media/zh-Hans/tour.jpg)](https://swiftycrow.pangmo5.dev/zh-Hans/#demo-tour)

规划一次港口之旅：翻译旅游指南并记入笔记，再用实时翻译查看不断变化的出发信息。各功能演示分别展示图解说明书、视频字幕、竖排日文杂志，以及独立窗口中的游戏对话。原创示例内容由真实开发版本翻译成韩语，应用界面使用本指南的语言。

<a id="features"></a>
## 主要功能

本 README 以 `main` 为准，包含尚未发布的更改。各版本的可用功能请查看[更新日志](CHANGELOG.md)。

<a id="capture-and-reuse"></a>
### 截图后用于自己的工作

<img align="right" src="../../web/media/zh-Hans/capture.jpg" width="200" alt="" />

[观看操作流程](https://swiftycrow.pangmo5.dev/zh-Hans/#demo-capture)

- **区域截图：** 拖动选择屏幕区域，或按 **Space**，像 macOS 截图工具一样选中整个窗口。结果会在浮动窗口中显示，译文直接覆盖在原文位置。支持保存或复制图片，也可单独复制原文或译文。

<br clear="right" />

<a id="follow-changing-content"></a>
### 跟随画面变化继续阅读

<img align="right" src="../../web/media/zh-Hans/live.jpg" width="200" alt="" />

[观看操作流程](https://swiftycrow.pangmo5.dev/zh-Hans/#demo-live)

- **实时翻译：** 用同样的方式选择目标，内容变化时会持续翻译。正文区域内的点击和滚动会传递给下方应用。**实时**按钮可暂停或继续，**×**可关闭。译文可显示在**原文上**，也可放到**独立窗口**，原位置仅保留区域边框。
- **预设区域，按需翻译：** 应用会记住上次区域，使用**显示或隐藏实时翻译**即可在同一位置切换翻译。适合游戏面板或固定位置的信息。隐藏后会停止所有截图和翻译，直到再次显示。
- **复用实时翻译：** 再次查看相同文字时，会复用之前的翻译结果。

<br clear="right" />

<a id="read-images-and-documents"></a>
### 阅读图片和文档

<img align="right" src="../../web/media/zh-Hans/layout.jpg" width="200" alt="" />

[观看操作流程](https://swiftycrow.pangmo5.dev/zh-Hans/#demo-layout)

- **识别文档结构：** 按阅读顺序识别竖排日文、中文和多栏文本，并根据译文语言选择合适的书写方向。
- **Mac 支持的语言：** 可选择 macOS 支持的源语言和目标语言。翻译前请下载所需模型。将源语言设为**自动检测**，即可逐行识别混合语言的内容。
- **两种翻译方式：** 选择**快速**以优先保证速度，或在运行 macOS 26.4 及以上版本的支持设备上选择**高质量**，使用 Apple Intelligence。

<br clear="right" />

<a id="keep-the-original-in-view"></a>
### 对照原文阅读

<img align="right" src="../../web/media/zh-Hans/compare.jpg" width="200" alt="" />

[观看操作流程](https://swiftycrow.pangmo5.dev/zh-Hans/#demo-compare)

- **选择阅读位置：** 在原文上显示译文，或在独立窗口中阅读，保留完整画面。隐藏翻译后，无需重新选择区域即可回到原来的位置。
- **常驻菜单栏：** 点击菜单栏图标打开控制面板，或按 `⌘,` 打开设置。
- **自定义快捷键：** 在设置 → 快捷键中配置截图、实时翻译、上次区域的显示与隐藏、暂停与继续、显示方式，以及保存和复制操作。
- **登录时启动：** 登录后自动启动 SwiftyCrow。
- **直接编辑配置文件：** 可手动编辑与应用内设置保持同步的文本文件。

<br clear="right" />

<a id="install"></a>
## 安装

需要 **macOS 26 或更高版本**。

**Homebrew**（推荐）：

```sh
brew install --cask PangMo5/tap/swiftycrow
```

**直接下载：** 从[发布页面](https://github.com/PangMo5/SwiftyCrow/releases/latest)获取最新的 `.dmg`，打开后将应用拖到“应用程序”文件夹。每个版本也提供对应源代码归档的链接。

首次启动时，请在系统设置 → 隐私与安全性中允许**屏幕录制**，然后重新启动应用。之后可通过应用获取更新。

<a id="usage"></a>
## 使用方法

1. 在设置（`⌘,`）中选择**源语言**和**目标语言**。
2. **截取区域：** 从控制面板或快捷键启动**截取区域**，再拖动框选文字。按 **Space** 可选择整个窗口。拖动结果窗口的标题区域可移动窗口。用 `⌘+` / `⌘−` 缩放，点击百分比或按 `⌘0` 使图片适合窗口；100% 表示一个图片像素对应一个屏幕像素。`⌘S` 保存、`⌘C` 复制图片、`⌘O` 复制原文、`⌘T` 复制译文、`Esc` 关闭。无论当前缩放比例或平移位置如何，保存和复制都会包含原始分辨率的完整图片。
3. **使用实时翻译：** 从菜单栏或快捷键启动**实时翻译…**，拖动选择区域，或按 **Space** 选择窗口。**实时**按钮可暂停或继续，`⌘C` 可复制全部译文，**×**可关闭。
4. **复用固定区域：** 选定区域后，使用**显示或隐藏实时翻译**即可在同一位置切换。隐藏后会停止所有截图和翻译。

截图、实时翻译和保存、复制操作的快捷键，可在设置 → 快捷键中修改。

<a id="troubleshooting"></a>
## 故障排查

<a id="unable-to-translate-or-a-missing-model-hint"></a>
### 翻译失败或提示缺少模型

SwiftyCrow 使用 Apple 的设备端翻译框架，需要先安装对应语言的模型。如果翻译失败或提示**语言模型尚未安装**，通常是因为检测到的语言模型还未下载。

**安装翻译模型：**

1. 打开**系统设置** → **通用** → **语言与地区**。
2. 向下滚动并选择**翻译语言…**。
3. 为源语言和目标语言**分别**点击**下载**。使用**自动检测**时，请安装截图中可能出现的所有语言。
4. 重新启动 SwiftyCrow 后再试。

应用中的**打开设置**按钮可直接跳转到相应设置。不再需要提醒时可选择**不再显示**。模型由 macOS 管理并保存在本机；可在同一面板删除不用的模型以释放空间。

详情请参阅 [docs/LANGUAGE_MODELS.md](LANGUAGE_MODELS.md)。

<a id="configuration"></a>
## 配置

设置保存在 `~/.config/SwiftyCrow/config.toml`，按应用的设置页分为 `[languages]`、`[overlay]`、`[shortcuts]`、`[translation]` 和 `[updates]` 表。应用内的修改与手动编辑文件的更改会保持同步。

所有键、默认值和快捷键语法请查看 [docs/CONFIGURATION.md](CONFIGURATION.md)。

<a id="development"></a>
## 开发

<a id="requirements"></a>
### 环境要求

- Xcode 26.4 或更高版本，包含 Swift 6.3 和 macOS 26.4 或更新的 SDK
- [mise](https://mise.jdx.dev)（通过 `.mise.toml` 管理 Tuist）
- 另行安装 SwiftFormat，用于源码格式化

<a id="building-from-source"></a>
### 从源码构建

```sh
export TUIST_DEVELOPMENT_TEAM=YOUR_TEAM_ID
export TUIST_SPARKLE_PUBLIC_ED_KEY=YOUR_SPARKLE_PUBLIC_KEY
mise install               # installs Tuist
tuist install              # resolves SPM dependencies
tuist generate             # generates the Xcode workspace
open SwiftyCrow.xcworkspace
```

Debug 构建使用 Apple Development 签名。请将 `TUIST_DEVELOPMENT_TEAM` 设为开发证书所属的团队。保持签名一致，可让 macOS 在重新构建后继续保留屏幕录制授权。将这些值写入 shell 配置或本地 `.mise.local.toml`：

```toml
[env]
TUIST_DEVELOPMENT_TEAM     = "YOUR_TEAM_ID"
TUIST_SPARKLE_PUBLIC_ED_KEY = "YOUR_SPARKLE_PUBLIC_KEY"
```

`TUIST_SPARKLE_PUBLIC_ED_KEY` 提供生成项目时写入 `Info.plist` 的公开验证密钥。该密钥必须有效，并与更新源的签名密钥匹配。使用官方更新源时，请使用发布版应用 `Contents/Info.plist` 中的 `SUPublicEDKey`。分支版本需要自己的更新源及匹配的公钥。

<a id="localization-and-site-previews"></a>
### 本地化与网站预览

术语和写作风格请遵循 [docs/LOCALIZATION.md](../LOCALIZATION.md)。应用目录、文档和网站使用相同的五种语言，每次构建应用前都会检查生成文件与目录是否一致。

```sh
swift run --package-path Tools swiftycrow-tools check
swift run --package-path Tools swiftycrow-tools docs
swift run --package-path Tools swiftycrow-tools site --output DerivedData/Site
swift run --package-path Tools swiftycrow-tools serve --output DerivedData/Site --port 8085
```

<a id="tech-stack"></a>
### 技术栈

- 由 **Tuist** 生成的工作区（`Project.swift`、`Tuist/Package.swift`）
- 使用 **TCA**（`swift-composable-architecture`）管理应用和截图状态，通过 `@DependencyClient` 注入依赖。
- 通过 **swift-sharing** 的 `fileStorage` 方式连接 **swift-toml**。
- 使用 **Magnet** 注册全局快捷键，并提供一个小型自定义快捷键录入控件。
- 应用内更新使用 **Sparkle**。
- 使用 **Apple Vision** 识别文字、**Apple 翻译**进行翻译、**ScreenCaptureKit** 截取屏幕。
- 使用 `.swiftformat` 中的 [Airbnb SwiftFormat](https://github.com/airbnb/swift) 配置统一源码格式。

<a id="license"></a>
## 许可证

[GNU Affero General Public License v3.0 only](../../LICENSE) (`AGPL-3.0-only`). Copyright (C) 2021-2026 PangMo5.

分发修改后的版本时，必须以相同许可证提供对应的源代码。第 13 条还要求通过网络使用的修改版向远程用户提供对应源代码。

本 README 和 `docs/LANGUAGE_MODELS.md` 包含此前以 MPL-2.0 提交的文档贡献，按文件中的说明，仍可选择 [MPL-2.0](https://www.mozilla.org/MPL/2.0/) 或 AGPL-3.0-only 使用。项目于 2021 年采用 MIT 许可证，2026 年先转为 MPL-2.0，再转为 AGPL-3.0-only。

所用软件包的许可证和确切源码修订记录在 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md) 中。该文件和许可证均包含在发布的应用包内。
