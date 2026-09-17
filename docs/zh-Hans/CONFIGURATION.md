<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 配置

本参考以 `main` 为准。已发布版本的设置请查看对应[发布标签](https://github.com/PangMo5/SwiftyCrow/tags)中的此文件。

SwiftyCrow 从以下位置读取配置：

```
~/.config/SwiftyCrow/config.toml
```

支持 XDG 路径。设置 `$XDG_CONFIG_HOME` 后，文件位于 `$XDG_CONFIG_HOME/SwiftyCrow/config.toml`。首次启动时创建文件，应用内每次修改设置后都会写回；编辑器中的更改也会在运行期间生效。

配置按应用的设置页面分为以下表：

- **`[languages]`：** 源语言和目标语言组合
- **`[overlay]`：** 实时翻译显示
- **`[shortcuts]`：** 全局快捷键和截图窗口快捷键
- **`[translation]`：** 翻译方式
- **`[updates]`：** 自动检查更新

以下项目**不保存在**此文件中：

- 翻译区域的位置和大小属于界面状态，保存在 `~/Library/Application Support/SwiftyCrow/overlay-frame.json`。

<a id="shortcut-syntax"></a>
## 快捷键语法

全局快捷键使用 skhd 风格：用 `+` 连接零个或多个修饰键，接着写 ` - `，最后写按键。

```
cmd + shift - c
ctrl + alt - space
cmd + ctrl + shift + alt - z
```

修饰键为 `cmd`、`ctrl`、`alt`（option）和 `shift`。按键可使用字母、数字、`tab`、`return`、`space`、方向键（`left`/`right`/`up`/`down`）、标点等。使用空字符串可解除该操作的快捷键。

实时截图会在画面变化时频繁检查，静止时放慢频率。仅在像素或语言设置变化时重新识别文字，滚动停止后立即刷新。旧 `[capture].interval` 设置会被忽略，并在下次保存时移除。

<a id="languages"></a>
## `[languages]`

源语言和目标语言分别使用嵌套表，包含 BCP-47 语言 `code`。列表以 macOS 支持的语言为准，源语言还需支持文字识别。所选语言组合的模型需要另外下载。

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`source.code`|string|`"auto"`|要翻译的**源语言**。默认 `"auto"` 会逐行检测截图中的文字，指定 `"en-US"` 等语言代码可固定语言。|
|`target.code`|string|系统语言|译文使用的**目标语言**，默认采用系统的首选语言。|

<a id="overlay"></a>
## `[overlay]`

点击菜单栏中的**实时翻译**按钮，或使用 `liveOverlay` 快捷键选择区域或窗口。再次点击按钮可选择新区域。内容区域的点击会传递给下方应用；控制按钮、调整大小的边缘和打开的信息面板会接收输入。使用 **实时** 暂停或继续，使用 **×** 关闭。

`toggleLiveOverlay` 快捷键和**显示悬浮翻译**开关可显示或隐藏所选区域的翻译。关闭时停止截图和翻译，重新开启时使用记住的区域。选择区域前，开关处于停用状态；没有保存的区域时，快捷键也不会执行操作。

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`hideOnHover`|bool|`false`|鼠标悬停时隐藏翻译层，便于阅读下方原文。|
|`liveMode`|string|`"inPlace"`|实时翻译的显示方式：`inPlace` 在原文上显示译文，`window` 仅保留区域边框，将译文放在独立窗口中。|

<a id="shortcuts"></a>
## `[shortcuts]`

所有值均为上述 skhd 格式的快捷键字符串。截图默认为 ⇧⌘1，实时区域选择默认为 ⇧⌘2；配置中省略这些键时也会采用默认值。明确指定的自定义快捷键会保留。空字符串可清除任何快捷键，包括其默认值。

**全局快捷键：** 应用在后台时也能使用。

|键|操作|
| --- | --- |
|`selectRegion`|截取区域。拖动选择范围，或按 Space 选择窗口。|
|`liveOverlay`|使用相同的选择方式开始实时翻译或更改区域。|
|`toggleLiveOverlay`|无需重新选择，在**上次使用的区域**显示或隐藏实时翻译。隐藏时停止截图和翻译，显示时恢复该区域并开始翻译。|
|`toggleLive`|保留屏幕上的区域，暂停或继续实时翻译。|
|`toggleLiveMode`|在原文上显示与独立窗口之间切换。|

**截图窗口快捷键：** 仅在结果窗口处于活动状态时生效，默认值如下：

|键|操作|默认值|
| --- | --- | --- |
|`regionSave`|保存图片|`cmd - s`|
|`regionCopyImage`|复制图片|`cmd - c`|
|`regionCopyOriginal`|复制原文|`cmd - o`|
|`regionCopyTranslation`|复制译文|`cmd - t`|

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
liveOverlay = "cmd + shift - o"
toggleLiveOverlay = "cmd + shift - k"
toggleLive = "cmd + shift - l"
toggleLiveMode = "cmd + shift - m"
```

> **2.6.0 更名：** `toggleOverlay` 键现为 `liveOverlay`。旧 `toggleOverlay` 项会被忽略，请在 `liveOverlay` 下重新绑定。

<a id="translation"></a>
## `[translation]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`strategy`|string|`"lowLatency"`|首选本地翻译方式为 `lowLatency` 或 `highFidelity`（macOS 26.4 及以上）。若对应模型已安装则优先使用，否则使用其他已安装模型并显示提示。|

<a id="updates"></a>
## `[updates]`

|键|类型|默认值|说明|
| --- | --- | --- | --- |
|`automaticChecks`|bool|`true`|在后台定期检查新版本。|
|`checkInterval`|string|`"daily"`|检查频率可选择 `hourly`、`daily` 或 `weekly`。|
