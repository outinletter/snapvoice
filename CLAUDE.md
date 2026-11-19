# SnapVoice

## 개요·기술 스택
- 키보드의 마이크 버튼을 누르고 있는 동안 말하면 손을 뗄 때 텍스트가 입력되는 iOS 키보드 확장 + 컨테이너 앱.
- Swift 5, iOS 17+, SwiftUI(앱) / UIKit(키보드), SFSpeechRecognizer(ko-KR), 로컬 DB 없음.
- 키보드 확장은 마이크를 못 쓰므로, 앱이 백그라운드 오디오 세션으로 마이크를 유지하고 키보드가 Darwin 알림 + App Group 공유 폴더의 파일로 시작/종료·결과를 주고받는다(UserDefaults는 프로세스 간 반영이 늦어 쓰지 않는다).
- Xcode 프로젝트는 xcodeproj gem 스크립트로 생성했다(폴더 동기화 그룹 아님). 새 파일은 pbxproj에 직접 추가해야 한다.

## 폴더 구조
- `App/` 컨테이너 앱 (UI, DictationEngine)
- `Keyboard/` 키보드 확장 (KeyboardViewController, HangulComposer 두벌식 조합기)
- `Shared/Bridge.swift` 두 타깃 공용 통신 코드 + `L(ko, en)` 문구 선택 함수
- `docs/AppStore.md` 제출 자료 초안, `PRIVACY.md` 처리방침(ko/en)

## 규칙
- 번들 ID `com.addvalue.snapvoicekeyboard`(키보드 확장 `.keyboard`), App Group `group.com.addvalue.snapvoicekeyboard`. 바꾸면 entitlements·Bridge.swift도 같이 바꾼다.
- 키보드 Info.plist `RequestsOpenAccess`=true 필수(App Group 접근).
- 외부 API 없이 기기 내 음성 인식만 사용.

## 명령어·현재 상태
- 스킴 `SnapVoice`, 타깃 `SnapVoice`, `SnapVoiceKeyboard`, 팀 A7QB8PT33N.
- 빌드: `xcodebuild -project SnapVoice.xcodeproj -scheme SnapVoice -destination 'generic/platform=iOS' -allowProvisioningUpdates -quiet build`
- 키보드 높이 기본 209pt(iPhone 16 Pro 기본 키보드 기준). 앱의 슬라이더(180~300)로 바꾸며 공유 폴더 `height` 파일로 전달한다.
- 심사 대응: 키보드에서 앱을 열지 않는다(4.4.1, Debug 빌드에서도 열지 않음). 세션이 꺼졌을 때는 동작 버튼/단축어의 App Intent(`App/AppIntents.swift`)로 켠다, 키에 이모지를 쓰지 않는다(5.2.5), 키 디자인은 기본 키보드와 구별되는 강조색·둥근 키를 유지한다.
- 세션은 앱이 활성화될 때 자동으로 켜진다(`autoStart`, 기본 켬). iOS는 키보드 확장의 마이크 사용과 백그라운드에서의 녹음 시작을 막으므로, 앱을 한 번도 열지 않은 상태에서 키보드만으로 받아쓰기를 시작할 수는 없다.
- 사용자에게 보이는 문구는 모두 `L("한국어", "English")`로 쓴다. 권한 문구는 `App/*.lproj/InfoPlist.strings`.
- 첫 실행 때 마이크 사용 동의(`onboarded`)를 받은 뒤에만 세션을 켠다. 세션은 `idleMinutes`(기본 1분, 선택지 1·3·5·15·30분, 끄지 않음 없음) 동안 안 쓰면 자동으로 꺼진다.
- 키보드 맨 아래 줄: `123 · 한/A · 누르고 말하기 · space · return`. 한/영은 전용 `한/A` 키(탭), 시작 언어는 앱의 "기본 언어" 설정.
- 개인정보 처리방침 URL: https://outinletter.github.io/privacy-policy/snapvoicekeyboard.html (앱 링크·App Store Connect 동일). 원문은 https://github.com/outinletter/privacy-policy 저장소의 `snapvoicekeyboard.html`에서 관리하고, 이 저장소의 PRIVACY.md는 사본이다.
- 앱 이름: App Store 이름 "SnapVoice Keyboard", 표시 이름(CFBundleDisplayName)·앱 화면 제목 `SnapVoiceKeyboard`. 코드 모듈명·타깃명은 `SnapVoice`를 유지한다(바꾸면 키보드 NSExtensionPrincipalClass 등이 깨진다).
- 키보드 화면은 `Keyboard/KeyCanvas.swift`의 단일 뷰(키 레이어 + 한 곳의 터치 처리, 가까운 키 30pt)로 그린다. 한글 조합은 지우고 쓰는 방식을 유지한다(임시 표시 marked text는 조합이 깨져 되돌림).
- 세션 중 햅틱이 막히지 않도록 `DictationEngine.activate`에서 `setAllowHapticsAndSystemSoundsDuringRecording(true)`를 켠다.
- 상태(2026-11-19): 1.0(빌드 2)은 App Store에 배포됨. 1.0.1(빌드 6: 키 캔버스, 햅틱 허용, 블루투스 A2DP 유지, 키 높이 확대, 반복·대기 시간 단축)을 업로드하고 업데이트 심사 제출 진행. 새 빌드는 항상 버전을 올리고 빌드 번호를 하나 더 올린다.
