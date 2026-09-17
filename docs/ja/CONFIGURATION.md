<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](../ko/CONFIGURATION.md) · [日本語](CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 設定

このリファレンスは`main`を基準にしています。リリース済みバージョンの設定は、対応する[リリースタグ](https://github.com/PangMo5/SwiftyCrow/tags)内のこのファイルをご確認ください。

SwiftyCrowは次の場所から設定を読み込みます：

```
~/.config/SwiftyCrow/config.toml
```

XDGのパスに対応しています。`$XDG_CONFIG_HOME`が設定されていれば、ファイルは`$XDG_CONFIG_HOME/SwiftyCrow/config.toml`に保存されます。初回起動時に作成し、アプリ内で設定を変えるたびに保存します。エディタでの変更もアプリの実行中に反映されます。

設定はアプリの設定画面に対応するテーブルに分かれています：

- **`[languages]`：** 原文と翻訳先の言語の組み合わせ
- **`[overlay]`：** ライブ翻訳の表示
- **`[shortcuts]`：** グローバルとキャプチャウインドウのショートカット
- **`[translation]`：** 翻訳方式
- **`[updates]`：** 自動更新の確認

次の項目はこのファイルには**保存しません**：

- 翻訳範囲の位置とサイズはUIの状態として`~/Library/Application Support/SwiftyCrow/overlay-frame.json`に保存します。

<a id="shortcut-syntax"></a>
## ショートカットの書式

グローバルショートカットはskhd形式で記述します。修飾キーを`+`でつなぎ、` - `の後にキーを書きます。修飾キーは省略できます。

```
cmd + shift - c
ctrl + alt - space
cmd + ctrl + shift + alt - z
```

修飾キーは`cmd`、`ctrl`、`alt`（option）、`shift`です。キーには英字、数字、`tab`、`return`、`space`、矢印キー（`left`/`right`/`up`/`down`）、記号などを使えます。空文字列を指定すると、その操作のショートカットを解除します。

ライブキャプチャは画面が変化するときは頻繁に確認し、静止しているときは間隔を長くします。ピクセルや言語設定が変わったときだけ文字を再認識し、スクロールが落ち着くとすぐ更新します。以前の`[capture].interval`設定は無視され、次の保存時にファイルから削除されます。

<a id="languages"></a>
## `[languages]`

原文と翻訳先をそれぞれ入れ子のテーブルに保存し、BCP-47の言語`code`を使います。一覧はmacOSの対応言語が基準で、原文の言語は文字認識にも対応している必要があります。選んだ言語の組み合わせのモデルは別途ダウンロードしてください。

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

|キー|型|初期値|説明|
| --- | --- | --- | --- |
|`source.code`|string|`"auto"`|翻訳する**原文の言語**です。初期値の`"auto"`はキャプチャした文章を行ごとに検出します。`"en-US"`のような言語コードを指定すると固定できます。|
|`target.code`|string|システムの言語|結果を表示する**翻訳先の言語**です。初期値はシステムで優先する言語です。|

<a id="overlay"></a>
## `[overlay]`

メニューバーの**ライブ翻訳**ボタンか`liveOverlay`ショートカットで、範囲やウインドウを選びます。ボタンをもう一度クリックすると新しい範囲を選べます。本文部分のクリックは背後のアプリに届き、操作ボタン、サイズ変更用の端、開いた情報ポップオーバーは入力を受け取ります。**ライブ**で一時停止・再開し、**×**で閉じます。

`toggleLiveOverlay`ショートカットと**オーバーレイを表示**スイッチで、選んだ範囲の翻訳を表示・非表示にできます。オフにするとキャプチャと翻訳は停止し、オンに戻すと記憶した範囲を使います。範囲を選ぶまではスイッチは無効で、保存済みの範囲がなければショートカットも動作しません。

|キー|型|初期値|説明|
| --- | --- | --- | --- |
|`hideOnHover`|bool|`false`|ポインタを重ねると翻訳表示を隠し、背後の原文を読めるようにします。|
|`liveMode`|string|`"inPlace"`|ライブ翻訳の表示方法です。`inPlace`は原文に訳文を重ね、`window`は範囲の枠だけを残して別ウインドウに訳文を表示します。|

<a id="shortcuts"></a>
## `[shortcuts]`

値はすべて上記のskhd形式の文字列です。キャプチャの既定値は⇧⌘1、ライブ範囲の選択は⇧⌘2で、設定からキーを省略した場合も適用されます。明示的に指定したキーは保持されます。空文字列を指定すると、既定値を含め、そのショートカットを解除します。

**グローバルショートカット：** ほかのアプリを使っているときも動作します。

|キー|操作|
| --- | --- |
|`selectRegion`|範囲をキャプチャします。ドラッグで範囲を選ぶか、Spaceでウインドウを選べます。|
|`liveOverlay`|同じ選択方法でライブ翻訳を開始するか、範囲を変更します。|
|`toggleLiveOverlay`|選び直さずに**前回の範囲**でライブ翻訳を表示・非表示にします。非表示にするとキャプチャ・翻訳を停止し、表示すると保存した範囲で再開します。|
|`toggleLive`|範囲を画面に残したまま、ライブ翻訳を一時停止・再開します。|
|`toggleLiveMode`|原文に重ねる表示と別ウインドウの表示を切り替えます。|

**キャプチャウインドウのショートカット：** 結果ウインドウが選択されているときだけ使えます。初期値は次のとおりです：

|キー|操作|初期値|
| --- | --- | --- |
|`regionSave`|画像を保存|`cmd - s`|
|`regionCopyImage`|画像をコピー|`cmd - c`|
|`regionCopyOriginal`|原文をコピー|`cmd - o`|
|`regionCopyTranslation`|訳文をコピー|`cmd - t`|

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
liveOverlay = "cmd + shift - o"
toggleLiveOverlay = "cmd + shift - k"
toggleLive = "cmd + shift - l"
toggleLiveMode = "cmd + shift - m"
```

> **2.6.0で名前を変更：** `toggleOverlay`キーは`liveOverlay`になりました。以前の`toggleOverlay`は無視されます。`liveOverlay`にショートカットを割り当て直してください。

<a id="translation"></a>
## `[translation]`

|キー|型|初期値|説明|
| --- | --- | --- | --- |
|`strategy`|string|`"lowLatency"`|優先する翻訳方式は`lowLatency`または`highFidelity`です（macOS 26.4以降）。そのモデルがインストールされていれば使い、なければ別のインストール済みモデルを使って案内します。|

<a id="updates"></a>
## `[updates]`

|キー|型|初期値|説明|
| --- | --- | --- | --- |
|`automaticChecks`|bool|`true`|バックグラウンドで新しいバージョンを定期的に確認します。|
|`checkInterval`|string|`"daily"`|確認の頻度は`hourly`、`daily`、`weekly`から選べます。|
