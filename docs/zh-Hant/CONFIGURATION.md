<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 設定

這份參考以 `main` 為準。已發布版本的設定請查看對應[發布標籤](https://github.com/PangMo5/SwiftyCrow/tags)中的此檔案。

SwiftyCrow 從以下位置讀取設定：

```
~/.config/SwiftyCrow/config.toml
```

支援 XDG 路徑。設定 `$XDG_CONFIG_HOME` 後，檔案位於 `$XDG_CONFIG_HOME/SwiftyCrow/config.toml`。首次啟動時建立檔案，App 內每次修改設定後都會寫回；編輯器中的變更也會在執行期間生效。

設定依 App 的設定頁面分為以下資料表：

- **`[languages]`：** 原文語言與翻譯語言組合
- **`[overlay]`：** 即時翻譯顯示
- **`[shortcuts]`：** 全域快速鍵與擷取視窗快速鍵
- **`[translation]`：** 翻譯方式
- **`[updates]`：** 自動檢查更新

以下項目**不儲存在**此檔案中：

- 翻譯區域的位置與大小屬於介面狀態，儲存在 `~/Library/Application Support/SwiftyCrow/overlay-frame.json`。

<a id="shortcut-syntax"></a>
## 快速鍵語法

全域快速鍵使用 skhd 風格：以 `+` 連接零個或多個修飾鍵，接著寫 ` - `，最後寫按鍵。

```
cmd + shift - c
ctrl + alt - space
cmd + ctrl + shift + alt - z
```

修飾鍵為 `cmd`、`ctrl`、`alt`（option）與 `shift`。按鍵可使用字母、數字、`tab`、`return`、`space`、方向鍵（`left`/`right`/`up`/`down`）、標點等。省略某項即可讓該操作不綁定快速鍵。

即時擷取會在畫面變更時頻繁檢查，靜止時放慢頻率。僅在像素或語言設定變更時重新辨識文字，捲動停止後立即更新。舊 `[capture].interval` 設定會被忽略，並在下次儲存時移除。

<a id="languages"></a>
## `[languages]`

原文語言與翻譯語言分別使用巢狀資料表，包含 BCP-47 語言 `code`。清單以 macOS 支援的語言為準，原文語言還需支援文字辨識。所選語言組合的模型需要另外下載。

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

|鍵|類型|預設值|說明|
| --- | --- | --- | --- |
|`source.code`|string|`"auto"`|要翻譯的**原文語言**。預設 `"auto"` 會逐行偵測擷取內容中的文字，指定 `"en-US"` 等語言代碼即可固定語言。|
|`target.code`|string|系統語言|譯文使用的**翻譯語言**，預設採用系統的偏好語言。|

<a id="overlay"></a>
## `[overlay]`

從選單列的**即時翻譯…**或 `liveOverlay` 快速鍵選取區域或視窗，即可開始即時翻譯。本文區域的點按會傳遞給下方 App，控制項、調整大小的邊緣與開啟的資訊視窗會接收輸入。用**即時**按鈕暫停或繼續，**×**關閉。

放置後的區域會被記住。使用 `toggleLiveOverlay` 快速鍵，或選單中的**顯示在上次區域**／**隱藏即時翻譯**，即可在相同位置切換，不必重新選取。隱藏會停止所有擷取與翻譯，再次顯示會還原該區域並開始即時翻譯，實現預設區域、隨需使用。

|鍵|類型|預設值|說明|
| --- | --- | --- | --- |
|`hideOnHover`|bool|`false`|游標停留時隱藏翻譯層，方便閱讀下方原文。|
|`liveMode`|string|`"inPlace"`|即時翻譯的顯示方式：`inPlace` 在原文上顯示譯文，`window` 僅保留區域邊框，將譯文放在獨立視窗中。|

<a id="shortcuts"></a>
## `[shortcuts]`

所有值均採用前述 skhd 風格的快速鍵字串。省略全域鍵表示不綁定該操作，這是預設行為。

**全域快速鍵：** App 在背景時也能使用。

|鍵|操作|
| --- | --- |
|`selectRegion`|擷取區域。拖移選取範圍，或按 Space 選取視窗。|
|`liveOverlay`|使用相同的選取方式開始即時翻譯或更改區域。|
|`toggleLiveOverlay`|不必重新選取，在**上次使用的區域**顯示或隱藏即時翻譯。隱藏時停止擷取與翻譯，顯示時還原該區域並開始翻譯。|
|`toggleLive`|保留螢幕上的區域，暫停或繼續即時翻譯。|
|`toggleLiveMode`|在原文上顯示與獨立視窗之間切換。|

**擷取視窗快速鍵：** 僅在結果視窗作用中時生效，預設值如下：

|鍵|操作|預設值|
| --- | --- | --- |
|`regionSave`|儲存影像|`cmd - s`|
|`regionCopyImage`|複製影像|`cmd - c`|
|`regionCopyOriginal`|複製原文|`cmd - o`|
|`regionCopyTranslation`|複製譯文|`cmd - t`|

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
liveOverlay = "cmd + shift - o"
toggleLiveOverlay = "cmd + shift - k"
toggleLive = "cmd + shift - l"
toggleLiveMode = "cmd + shift - m"
```

> **2.6.0 重新命名：** `toggleOverlay` 鍵現為 `liveOverlay`。舊 `toggleOverlay` 項目會被忽略，請在 `liveOverlay` 下重新綁定。

<a id="translation"></a>
## `[translation]`

|鍵|類型|預設值|說明|
| --- | --- | --- | --- |
|`strategy`|string|`"lowLatency"`|偏好的本機翻譯方式為 `lowLatency` 或 `highFidelity`（macOS 26.4 以上）。若對應模型已安裝則優先使用，否則使用其他已安裝模型並顯示提示。|

<a id="updates"></a>
## `[updates]`

|鍵|類型|預設值|說明|
| --- | --- | --- | --- |
|`automaticChecks`|bool|`true`|在背景定期檢查新版本。|
|`checkInterval`|string|`"daily"`|檢查頻率可選擇 `hourly`、`daily` 或 `weekly`。|
