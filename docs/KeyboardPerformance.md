# 키보드 입력 성능·정확도 수정 정리 (SnapVoice → NativeTone 이식용)

기준: NativeTone 키보드 구조(키마다 `KeyButton`, `UIStackView` 배치, 뗄 때 입력)를 SnapVoice에 가져온 뒤 추가한 수정이다.
실기기에서 체감이 좋아졌다는 확인은 있고, 항목별 효과를 따로 측정한 것은 아니다. 측정은 7번 항목의 `Metrics`로 한다.

## 이식 우선순위

| 순위 | 항목 | 효과 | 위험 | NativeTone에서 할 일 |
|---|---|---|---|---|
| 1 | 입력창 앱으로 보내는 요청 줄이기 (영어 합치기, 읽기 호출 제거) | 큼 | 낮음 | 2번, 3번 |
| 2 | 햅틱을 Core Haptics + 백그라운드로 | 중간 | 낮음 | 4번 |
| 3 | 키 미리보기 풍선 재사용 | 작음~중간 | 낮음 | 5번 |
| 4 | 화면 가장자리 터치 지연 끄기 | 작음(가장자리 키) | 낮음 | 6번 |
| 5 | 삭제 반복 타이밍 | 체감 | 낮음 | 8번 |
| 6 | 성능 측정 도구 | 판단 근거 | 없음(개발 빌드만) | 7번 |

## 1. 원인 정리
- 키보드 확장은 입력창 앱 안에서 도는 기본 키보드와 달리, 글자를 넣을 때마다 입력창 앱에 요청을 보내고 앱이 한 줄로 처리한다. 빠르게 치면 요청이 밀리고, 문서가 길수록 느려진다.
- 그래서 **요청 횟수를 줄이는 것**이 가장 효과가 크고, 키보드 쪽 작업(진동, 뷰 생성)을 줄이는 것이 그다음이다.

## 2. 영어 입력 요청 합치기 — `KeyboardViewController.swift` `hostInsert`, `flushPending`, `hostInsertNow`
- 영어 글자와 스페이스는 직전 전송 후 12ms 안에 다시 입력되면 문자열에 쌓았다가 한 번에 `insertText`로 보낸다. 12ms 이후면 바로 보낸다(평소 속도에서는 지연이 늘지 않음).
- **순서 보장 규칙:** 삭제(`hostDelete`), 입력창 읽기(`hostRead`), 줄바꿈·받아쓰기·한글처럼 바로 보내는 입력(`hostInsertNow`)은 항상 먼저 `flushPending()`을 부른다. 이 규칙을 빼먹으면 글자 순서가 뒤바뀐다.
- 언어 전환(`toggleLanguage`)과 화면이 사라질 때(`viewWillDisappear`)도 밀린 글자를 내보낸다.
- NativeTone: 영어 입력 경로의 `type(_:)`이 이 합치기를 쓰게 하면 된다. 한글·일본어·중국어는 이미 키보드 안 버퍼에 모으므로 해당 없음.

## 3. 입력창 읽기(`documentContextBeforeInput`) 줄이기
- SnapVoice: 한글 조합 상태 확인용 읽기를 0.8초 넘게 쉰 뒤에만 한다(`syncComposer`). 읽는 동안 키보드가 멈추기 때문이다.
- NativeTone: `textDidChange`가 호출될 때마다 `updateAutoShift`가 `documentContextBeforeInput`을 읽는다(영어 레이어). 키를 칠 때마다 동기 읽기가 생기므로 **가장 먼저 줄일 곳**이다. 방법: 스페이스·줄바꿈·삭제 직후에만 갱신하거나, 마지막 갱신 후 일정 시간(예: 0.3초) 안에는 건너뛴다.

## 4. 햅틱 — `Haptics` 클래스 (`KeyboardViewController.swift` 상단)
- `UIImpactFeedbackGenerator`를 매 터치마다 새로 만들어 메인 스레드에서 울리던 것을 Core Haptics로 바꿨다.
  - `CHHapticEngine`을 한 번 만들어 두고 `playsHapticsOnly = true`, `isAutoShutdownEnabled = false`.
  - 진동 요청은 `userInteractive` 큐에서 한다. 메인 스레드를 막지 않는다.
  - 35ms보다 빠른 연타는 건너뛴다(진동이 뭉쳐 길게 느껴지는 것 방지).
  - 엔진이 멈추면(`stoppedHandler`, `resetHandler`) 한 번만 다시 만들고, 못 쓰면 `failed`로 기록해 키마다 재시도하지 않는다. 못 쓸 때만 UIKit 진동으로 대신한다.
  - 전체 접근 허용이 꺼져 있으면(`enabled = false`) 아예 시도하지 않는다. 키보드가 열릴 때 `Haptics.shared.enabled = hasFullAccess`, `prepare()`.
- **녹음 중 햅틱이 막히는 문제(음성 앱만 해당):** 마이크 녹음 세션이 켜져 있으면 iOS가 진동을 막는다. `AVAudioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)`로 해결했다(`DictationEngine.swift`). NativeTone은 녹음이 없어 필요 없다.
- NativeTone: `KeyButton.swift`의 `UIImpactFeedbackGenerator(style: .light).impactOccurred()`(touchDown, FlickKey의 touchesBegan 포함)를 `Haptics.shared.tap()`으로 교체.

## 5. 키 미리보기 풍선 재사용 — `KeyButton.swift` `showPopup`, `popupHost`
- 눌릴 때마다 `UILabel`을 만들고 붙이던 것을, 라벨 하나를 `static`으로 만들어 두고 위치와 글자만 바꾼다. `popupHost`(키보드 뷰)에 한 번 붙이고 `isHidden`으로 켜고 끈다.
- 위치는 `convert(bounds, to: host)`로 구하고 좌우를 뷰 밖으로 나가지 않게 보정한다.
- 맨 윗줄은 위 공간이 없어 키 위에 겹쳐 그린다(`popupAbove = false`). NativeTone은 상단 바가 있어 위로 그릴 수 있으니 이 플래그는 필요하면 쓴다.
- 부수 효과: 키 레이어의 `zPosition` 변경이 필요 없어졌다.

## 6. 화면 가장자리 터치 지연 — `viewDidAppear`
- `view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }`
- iOS가 홈 제스처와 겹치는 가장자리 터치를 일부러 늦추는 것을 끈다. 맨 왼쪽·오른쪽·맨 아래 줄 키가 굼뜨던 현상 완화.

## 7. 성능 측정 도구 (디버그 빌드 전용) — `Metrics.swift`, 앱의 측정 화면
- `Metrics.shared.time("이름") { ... }`로 구간 시간을 재고, 상위 5%(`p95`)와 최대를 App Group 파일로 앱에 넘긴다. 배포 빌드에서는 `#if DEBUG`로 아무 일도 하지 않는다.
- 측정 지점: `ko.type`/`en.type`(키 처리), `proxy.insert/delete/read`(입력창 요청 시간), `touchDown`(누르는 순간 작업), `key.interval`(키 간격), `frame.gap`(25ms 넘는 화면 멈춤, `CADisplayLink`).
- 해석: `proxy.*`가 크면 입력창 앱 쪽 병목, `touchDown`·`frame.gap`이 크면 키보드 쪽 병목.
- 이식: `Metrics.swift`를 복사하고 `Bridge.Key.metrics`, `metricsReset` 키와 앱의 측정 화면(`SnapVoiceApp.swift`의 `#if DEBUG` 블록)을 옮기면 된다.

## 8. 삭제 키 반복 — `KeyButton.swift` `beginRepeat`
- 반복 시작 0.4초 → 0.25초, 반복 간격 0.07초 → 0.06초. 입력창 앱 처리가 밀릴 만큼 빠르면 손을 뗀 뒤에도 계속 지워지니, 그런 증상이 보이면 간격을 0.08~0.1초로 늘린다.

## 9. 키보드 높이·레이아웃
- 상단 바를 없애면서 키 크기를 NativeTone과 맞추려고 기본 높이를 232pt로 했다(NativeTone 보통 276pt − 바 44pt + 여백). 가로 모드는 162pt 이하로 낮춘다(`applyHeight`).
- 앱의 슬라이더로 높이를 바꾸고 `Bridge`로 전달한다(SnapVoice 전용 기능).

## 10. 시도했다가 되돌린 것 (NativeTone에는 적용하지 말 것)
| 시도 | 결과 |
|---|---|
| 한글 조합을 `setMarkedText`(임시 표시)로 한 번에 교체 | 조합이 깨짐("타자입력" → "ㅌ자이ㄹ력"). 입력창 앱마다 동작이 달랐다. |
| 커서 이동을 `selectionDidChange`로 감지해 조합 상태 초기화 | 우리 입력 직후에도 알림이 와서 조합이 끊김. |
| 키를 한 뷰의 레이어로 직접 그리고 터치를 한 곳에서 처리, 가장 가까운 키(30pt)로 보정 | 키 사이 빈틈 오타와 손가락이 굴러서 옆 키가 입력되는 오타가 늘었다고 느껴졌다. NativeTone 방식(키마다 버튼, 처음 닿은 키 기준으로 뗄 때 입력)이 더 정확했다. |
| 닿는 순간 입력 | 손가락이 닿은 뒤 굴러서 옆 키로 가는 오타 증가. |
| 전체 키에 `isMultipleTouchEnabled = true` | 체감 개선 없음. 제거. |

## 11. NativeTone이 이미 더 나은 점 (건드리지 말 것)
- 한글·일본어·중국어를 키보드 안 버퍼(`compose buffer`)에 모아 두기 때문에 입력창 요청이 키마다 가지 않는다. 이 구조가 한글 속도의 가장 큰 이유다. SnapVoice는 한글을 입력창에 바로 넣어야 해서 쓸 수 없다.
- 뗄 때 입력(`touchUpInside`)과 처음 닿은 키 기준 입력.

## 참고 파일
- [KeyboardViewController.swift](../Keyboard/KeyboardViewController.swift) — `Haptics`, 요청 합치기, 측정 훅
- [KeyButton.swift](../Keyboard/KeyButton.swift) — 풍선 재사용, 삭제 반복, 터치 처리
- [Metrics.swift](../Keyboard/Metrics.swift) — 측정 도구
- [DictationEngine.swift](../App/DictationEngine.swift) — 녹음 중 햅틱 허용(음성 앱 전용)
