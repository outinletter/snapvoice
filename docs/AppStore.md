# App Store 제출 자료 (초안)

App Store Connect에 붙여 넣을 내용이다. 스크린샷과 시연 영상은 직접 준비해야 한다.

## 기본 정보
- 이름: SnapVoice Keyboard (App Store Connect 앱 이름). 홈 화면·키보드 목록 표시 이름은 `SnapVoiceKeyboard`(CFBundleDisplayName)
- 상표는 KIPRIS·USPTO에서 직접 조회
- 부제(ko): 누르고 말하면 바로 입력되는 키보드
- 부제(en): Hold-to-talk dictation keyboard
- 카테고리: 유틸리티 (보조: 생산성)
- 연령 등급: 4+
- 가격: 무료
- 개인정보 처리방침 URL: https://outinletter.github.io/privacy-policy/snapvoicekeyboard.html
- 지원 URL: https://github.com/outinletter/snapvoice/issues

## 설명 (ko)
SnapVoice Keyboard는 버튼을 누르고 있는 동안에만 받아쓰는 키보드입니다. 마이크를 켜고 끄는 대신, '누르고 말하기'를 누른 채 말하고 손을 떼면 바로 글자가 입력됩니다.

- 누르고 있는 동안만 듣는 받아쓰기
- 한글 두벌식·영어 자판과 숫자·기호 자판
- 한국어·영어 음성 인식 (한/A 키로 전환)
- 키보드 높이 조절, 키 햅틱
- 계정·광고·분석 도구 없음. 개발자는 어떤 데이터도 수집하지 않습니다

받아쓰기를 쓰려면 키보드 설정에서 '전체 접근 허용'을 켜고 SnapVoice Keyboard 앱에서 음성 세션을 켜야 합니다. 글자 입력은 전체 접근 없이도 됩니다.

## Description (en)
SnapVoice Keyboard is a keyboard that listens only while you hold a key. Instead of toggling a microphone on and off, hold "Hold to talk", speak, and let go — your words are typed right away.

- Dictation only while you hold the key
- Korean (2-set) and English layouts with numbers and symbols
- Korean and English speech recognition (switch with the 한/A key)
- Adjustable keyboard height and key haptics
- No accounts, ads, or analytics. The developer collects no data

To dictate, turn on Allow Full Access for the keyboard and turn on a voice session in the SnapVoice Keyboard app. Typing works without Full Access.

## 키워드
ko: 받아쓰기,음성입력,키보드,음성인식,말하기,타이핑,한글,딕테이션
en: dictation,voice typing,keyboard,speech to text,hold to talk,korean

## 개인정보 라벨 (App Privacy)
- "데이터를 수집하지 않음" 선택.
- 근거: 개발자 서버·SDK가 없다. 음성은 Apple 음성 인식(SFSpeechRecognizer)이 처리하며, 기기 내 인식을 지원하지 않을 때만 Apple로 전송된다. Apple 지침상 개발자가 받지 않는 데이터는 수집으로 보지 않는다.

## 수출 규정
- 암호화 미사용. Info.plist에 `ITSAppUsesNonExemptEncryption = NO` 설정됨.

## 심사 메모 (App Review Notes, 영어로 제출)
SnapVoice Keyboard is a custom keyboard with a hold-to-talk dictation key. No login is required.

How to test:
1. Open the SnapVoice Keyboard app, read the explanation, and tap "Agree and turn on voice session". Allow Microphone and Speech Recognition.
2. Settings > General > Keyboard > Keyboards > Add New Keyboard > SnapVoice Keyboard, then turn on Allow Full Access.
3. Open Notes, switch to SnapVoice Keyboard with the globe key, hold the "Hold to talk" key, speak, and release. The text is inserted.

Why background audio is used (Guideline 2.5.4 / 2.5.14):
iOS does not allow keyboard extensions to access the microphone. The containing app therefore keeps an audio session open while the user has explicitly turned on a "voice session", and the keyboard only signals when the key is pressed and released. Audio is transcribed only while the key is held; nothing is recorded to disk. The iOS microphone indicator is visible for the whole session, the user consents on first launch, can turn the session off at any time, and it turns off automatically after the chosen idle time (1 minute by default).

Guideline 4.4.1:
- Typing works without Full Access and without network access. Full Access is used only for on-device communication with the containing app (App Group) for dictation.
- The keyboard never launches the containing app or any other app. If the voice session is off, the key only shows a hint; the user restarts the session from the app, or with the Action Button / Shortcuts ("Start voice session").
- Language switching uses a dedicated 한/A key; no key is repurposed.
- The system globe key (or our own globe key on devices without one) advances to the next keyboard.
- The keyboard does not use emoji and has its own visual design.

Privacy: no data is collected by the developer. Speech is processed by Apple's Speech framework, on device when supported.

## 제출 전 직접 할 일
- 개인정보 처리방침은 privacy-policy 저장소의 `snapvoicekeyboard.html`로 게시됨(2026-11-17). 앱 링크와 App Store Connect URL을 모두 위 주소로 입력한다.
- 스크린샷: 6.9" iPhone (1320×2868) 최소 3장 — 키보드로 받아쓰는 화면, 앱의 세션 화면, 설정 방법.
- 시연 영상을 심사 메모에 링크로 첨부.
- Xcode에서 Archive → App Store Connect 업로드 (배포용 서명).
- 버전 1.0 (빌드 1). 다시 올릴 때는 빌드 번호를 올린다.
