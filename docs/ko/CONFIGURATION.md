<!-- LANGUAGE-LINKS:START -->
[English](../CONFIGURATION.md) · [한국어](CONFIGURATION.md) · [日本語](../ja/CONFIGURATION.md) · [简体中文](../zh-Hans/CONFIGURATION.md) · [繁體中文](../zh-Hant/CONFIGURATION.md)
<!-- LANGUAGE-LINKS:END -->

<a id="configuration"></a>
# 설정

이 안내는 `main` 기준이에요. 배포된 버전의 설정은 해당 [릴리스 태그](https://github.com/PangMo5/SwiftyCrow/tags)에서 이 파일을 확인해 주세요.

SwiftyCrow는 다음 위치에서 설정을 읽어요:

```
~/.config/SwiftyCrow/config.toml
```

XDG 경로를 지원해요. `$XDG_CONFIG_HOME`이 설정되어 있으면 파일은 `$XDG_CONFIG_HOME/SwiftyCrow/config.toml`에 저장돼요. 처음 실행할 때 파일을 만들고 앱에서 설정을 바꿀 때마다 저장해요. 편집기로 바꾼 내용도 앱 실행 중에 반영돼요.

설정은 앱 설정 화면에 맞춰 테이블로 나뉘어요:

- **`[languages]`:** 원문·번역 언어 조합
- **`[overlay]`:** 실시간 번역 표시
- **`[shortcuts]`:** 전역 단축키와 캡처 창 단축키
- **`[translation]`:** 번역 방식
- **`[updates]`:** 자동 업데이트 확인

다음 항목은 이 파일에 **저장하지 않아요**:

- 번역 영역의 위치와 크기는 UI 상태로서 `~/Library/Application Support/SwiftyCrow/overlay-frame.json`에 저장돼요.

<a id="shortcut-syntax"></a>
## 단축키 표기법

전역 단축키는 skhd 형식으로 적어요. 수정 키를 `+`로 연결하고, ` - ` 다음에 키를 적으면 돼요. 수정 키를 생략할 수도 있어요.

```
cmd + shift - c
ctrl + alt - space
cmd + ctrl + shift + alt - z
```

수정 키는 `cmd`, `ctrl`, `alt`(option), `shift`예요. 키에는 영문자, 숫자, `tab`, `return`, `space`, 방향 키(`left`/`right`/`up`/`down`), 문장 부호 등을 쓸 수 있어요. 빈 문자열을 넣으면 해당 동작의 단축키를 해제해요.

실시간 캡처는 화면이 바뀔 때 자주 확인하고 정지해 있을 때는 간격을 늘려요. 바뀐 픽셀이나 언어 설정이 있을 때만 글자를 다시 인식하고, 스크롤이 멈추면 바로 갱신해요. 이전 `[capture].interval` 설정은 무시되며 다음 저장 때 파일에서 빠져요.

<a id="languages"></a>
## `[languages]`

원문과 번역 언어를 각각 중첩 테이블로 저장하며, BCP-47 언어 `code`를 사용해요. 목록은 macOS 지원 언어를 기준으로 하고 원문 언어는 글자 인식도 지원해야 해요. 선택한 언어 조합의 모델은 별도로 다운로드해야 해요.

```toml
[languages.source]
code = "auto"

[languages.target]
code = "ko-KR"
```

|키|유형|기본값|설명|
| --- | --- | --- | --- |
|`source.code`|string|`"auto"`|번역할 **원문 언어**예요. 기본값 `"auto"`는 캡처한 글을 줄마다 감지해요. `"en-US"` 같은 언어 코드를 지정하면 해당 언어로 고정돼요.|
|`target.code`|string|시스템 언어|번역 결과를 표시할 **번역 언어**예요. 기본값은 시스템의 기본 언어예요.|

<a id="overlay"></a>
## `[overlay]`

메뉴 막대의 **실시간 번역** 버튼이나 `liveOverlay` 단축키로 영역 또는 창을 고르세요. 버튼을 다시 누르면 새 영역을 선택해요. 본문 영역의 클릭은 뒤쪽 앱으로 전달되고, 제어 버튼·크기 조절 가장자리·열린 정보창은 입력을 받아요. **실시간**으로 멈추거나 다시 시작하고 **×**로 닫을 수 있어요.

`toggleLiveOverlay` 단축키와 **오버레이 표시** 스위치로 선택한 영역의 번역을 켜고 끌 수 있어요. 끄면 캡처와 번역이 멈추고, 다시 켜면 기억한 영역을 사용해요. 영역을 고르기 전에는 스위치가 비활성화되며 단축키도 동작하지 않아요.

|키|유형|기본값|설명|
| --- | --- | --- | --- |
|`hideOnHover`|bool|`false`|마우스를 올리면 번역 화면을 숨겨 뒤쪽 원문을 읽을 수 있게 해요.|
|`liveMode`|string|`"inPlace"`|실시간 번역 표시 방식이에요. `inPlace`는 원문 위에 번역을 표시하고, `window`는 영역 테두리만 남긴 채 번역문을 별도 창에 보여줘요.|

<a id="shortcuts"></a>
## `[shortcuts]`

모든 값은 위에서 설명한 skhd 형식의 단축키 문자열이에요. 캡처 기본값은 ⇧⌘1, 실시간 영역 선택 기본값은 ⇧⌘2이며 설정 파일에 해당 키가 없어도 적용돼요. 직접 지정한 단축키는 유지해요. 빈 문자열을 넣으면 기본값을 포함해 해당 단축키를 해제해요.

**전역 단축키:** 다른 앱을 사용 중이어도 동작해요.

|키|동작|
| --- | --- |
|`selectRegion`|영역을 캡처해요. 드래그로 영역을 선택하거나 Space로 창을 선택할 수 있어요.|
|`liveOverlay`|같은 선택 방식으로 실시간 번역을 시작하거나 영역을 바꿔요.|
|`toggleLiveOverlay`|다시 선택하지 않고 **마지막 영역**에 실시간 번역을 표시하거나 숨겨요. 숨기면 캡처·번역을 멈추고, 표시하면 저장된 영역에서 다시 시작해요.|
|`toggleLive`|영역은 화면에 둔 채 실시간 번역을 멈추거나 다시 시작해요.|
|`toggleLiveMode`|원문 위 표시와 별도 창 사이에서 표시 방식을 바꿔요.|

**캡처 창 단축키:** 캡처 결과 창이 선택되어 있을 때만 동작해요. 기본값은 다음과 같아요:

|키|동작|기본값|
| --- | --- | --- |
|`regionSave`|이미지 저장|`cmd - s`|
|`regionCopyImage`|이미지 복사|`cmd - c`|
|`regionCopyOriginal`|원문 복사|`cmd - o`|
|`regionCopyTranslation`|번역문 복사|`cmd - t`|

```toml
[shortcuts]
selectRegion = "cmd + shift - c"
liveOverlay = "cmd + shift - o"
toggleLiveOverlay = "cmd + shift - k"
toggleLive = "cmd + shift - l"
toggleLiveMode = "cmd + shift - m"
```

> **2.6.0에서 이름 변경:** `toggleOverlay` 키가 `liveOverlay`로 바뀌었어요. 이전 `toggleOverlay` 항목은 무시돼요. `liveOverlay`에 단축키를 다시 지정해 주세요.

<a id="translation"></a>
## `[translation]`

|키|유형|기본값|설명|
| --- | --- | --- | --- |
|`strategy`|string|`"lowLatency"`|기본 번역 방식은 `lowLatency` 또는 `highFidelity`예요(macOS 26.4 이상). 해당 모델이 설치되어 있으면 우선 사용하고, 없으면 설치된 다른 모델을 사용한 뒤 알려드려요.|

<a id="updates"></a>
## `[updates]`

|키|유형|기본값|설명|
| --- | --- | --- | --- |
|`automaticChecks`|bool|`true`|백그라운드에서 새 버전을 주기적으로 확인해요.|
|`checkInterval`|string|`"daily"`|확인 주기는 `hourly`, `daily`, `weekly` 중에서 선택해요.|
