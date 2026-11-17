import SwiftUI

@main
struct SnapVoiceApp: App {
    @StateObject private var engine = DictationEngine.shared
    @Environment(\.scenePhase) private var phase
    @AppStorage("autoStart") private var autoStart = true
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
        // 마이크 사용에 동의한 뒤로는 앱을 열기만 하면 세션이 켜진다.
        .onChange(of: phase, initial: true) { _, p in
            if p == .active && autoStart && onboarded { engine.startSession() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var engine: DictationEngine
    @State private var height = Bridge.keyboardHeight
    @State private var sample = ""
    @State private var defaultLang = Bridge.get(Bridge.Key.defaultLang).isEmpty ? "ko" : Bridge.get(Bridge.Key.defaultLang)
    @AppStorage("autoStart") private var autoStart = true
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("idleMinutes") private var idleMinutes = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("SnapVoiceKeyboard").font(.largeTitle.bold()).lineLimit(1).minimumScaleFactor(0.6)
                Text(L("키보드의 '누르고 말하기' 버튼을 누르고 있는 동안 말하면, 손을 뗄 때 바로 입력됩니다.",
                       "Hold the Hold to talk key on the keyboard and speak. Your words are typed when you let go."))
                    .foregroundStyle(.secondary)

                GroupBox(L("기본 언어", "Default language")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(L("키보드 시작 언어", "Keyboard starts in"), selection: $defaultLang) {
                            Text("한글").tag("ko")
                            Text("English").tag("en")
                            Text(L("마지막 사용", "Last used")).tag("last")
                        }.pickerStyle(.segmented)
                        Text(L("받아쓰기 언어도 키보드 언어를 따릅니다. 키보드의 space 바를 좌우로 밀면 언제든 바꿀 수 있습니다. 이메일·URL 칸은 항상 영어로 시작합니다.",
                               "Dictation uses the keyboard's language. Swipe the space bar left or right to switch any time. Email and URL fields always start in English."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: defaultLang) { _, v in Bridge.set(v, Bridge.Key.defaultLang) }

                if onboarded { sessionControls } else { consent }

                GroupBox(L("키보드 높이", "Keyboard height")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Slider(value: $height, in: Bridge.heightRange, step: 1)
                                .accessibilityLabel(L("키보드 높이", "Keyboard height"))
                            Text("\(Int(height))").monospacedDigit().frame(width: 36)
                            Button(L("기본값", "Reset")) { height = Bridge.defaultHeight }.font(.footnote)
                        }
                        TextField(L("여기를 눌러 키보드를 띄워 보세요", "Tap here to try the keyboard"), text: $sample, axis: .vertical)
                            .textFieldStyle(.roundedBorder).font(.footnote)
                    }
                }
                .onChange(of: height) { _, h in
                    Bridge.set(String(h), Bridge.Key.height); Bridge.post(.config)
                }

                GroupBox(L("설정 방법", "Setup")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("1. 설정 ▸ 일반 ▸ 키보드 ▸ 키보드 ▸ 새로운 키보드 추가 ▸ SnapVoiceKeyboard",
                               "1. Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ SnapVoiceKeyboard"))
                        Text(L("2. SnapVoiceKeyboard ▸ '전체 접근 허용' 켜기 (받아쓰기에만 필요, 글자 입력은 없어도 됨)",
                               "2. SnapVoiceKeyboard ▸ turn on Allow Full Access (needed only for dictation; typing works without it)"))
                        Text(L("3. 이 앱을 열어 음성 세션 켜기 ▸ 다른 앱으로 이동",
                               "3. Open this app to turn the voice session on ▸ switch to another app"))
                        Text(L("   세션이 꺼졌을 땐 동작 버튼으로 다시 켤 수 있습니다: 설정 ▸ 동작 버튼 ▸ 단축어 ▸ SnapVoiceKeyboard '음성 세션 켜기/끄기' (누르면 켜지고 다시 누르면 꺼짐)",
                               "   If the session turns off, restart it with the Action Button: Settings ▸ Action Button ▸ Shortcut ▸ SnapVoiceKeyboard \"Toggle voice session\" (press to turn on, press again to turn off)"))
                        Text(L("4. 지구본 키로 SnapVoiceKeyboard 키보드 선택 ▸ '누르고 말하기'를 누른 채 말하기",
                               "4. Pick SnapVoiceKeyboard with the globe key ▸ hold Hold to talk and speak"))
                        Button(L("설정 열기", "Open Settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox(L("개인정보", "Privacy")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("'전체 접근 허용'은 키보드가 이 앱과 받아쓰기 신호·결과를 주고받는 데만 씁니다. 키보드로 입력한 내용은 저장하거나 외부로 보내지 않습니다.",
                               "Full Access is used only so the keyboard and this app can exchange dictation signals and results on your device. What you type is never stored or sent anywhere."))
                        Text(L("음성은 버튼을 누르고 있는 동안에만 Apple 음성 인식으로 글자로 바뀝니다. 기기 내 인식을 지원하지 않는 경우 음성이 Apple 서버로 전송될 수 있습니다. 개발자는 음성이나 글을 수집하지 않습니다.",
                               "Speech is transcribed by Apple speech recognition only while you hold the button. If on-device recognition is unavailable, audio may be sent to Apple. The developer collects no audio or text."))
                        Link(L("개인정보 처리방침", "Privacy Policy"), destination: URL(string: "https://outinletter.github.io/privacy-policy/snapvoice.html")!)
                    }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
    }

    /// 테스트 받아쓰기 언어: "기본 언어" 설정을 따른다 (마지막 사용이면 키보드에서 마지막에 쓴 언어).
    private var testLocale: String {
        switch defaultLang {
        case "en": return "en-US"
        case "last": return Bridge.get(Bridge.Key.lang) == "en" ? "en-US" : "ko-KR"
        default: return "ko-KR"
        }
    }

    /// 처음 한 번: 마이크가 어떻게 쓰이는지 알리고 동의를 받는다.
    private var consent: some View {
        GroupBox(L("시작하기 전에", "Before you start")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("iOS는 키보드가 마이크를 직접 쓰지 못하게 합니다. 그래서 이 앱이 '음성 세션'을 켜 둔 동안 마이크를 대신 열어 둡니다.",
                       "iOS does not let keyboards use the microphone. Instead, this app keeps the microphone open while a voice session is on."))
                Text(L("• 세션이 켜져 있으면 화면 위에 마이크 표시가 보입니다.\n• 음성은 '누르고 말하기'를 누르는 동안에만 글자로 바뀌고, 녹음 파일로 저장되지 않습니다.\n• 일정 시간 쓰지 않으면 세션이 자동으로 꺼지고, 언제든 직접 끌 수 있습니다.",
                       "• While a session is on, the microphone indicator is shown at the top of the screen.\n• Speech is transcribed only while you hold Hold to talk, and is never saved as a recording.\n• The session turns off automatically when unused, and you can turn it off at any time."))
                Button {
                    onboarded = true
                    engine.startSession()
                } label: {
                    Text(L("동의하고 음성 세션 켜기", "Agree and turn on voice session")).frame(maxWidth: .infinity).padding(8)
                }.buttonStyle(.borderedProminent)
            }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var sessionControls: some View {
        Button {
            engine.running ? engine.stopSession() : engine.startSession()
        } label: {
            Label(engine.running ? L("음성 세션 끄기", "Turn off voice session") : L("음성 세션 켜기", "Turn on voice session"),
                  systemImage: engine.running ? "stop.circle.fill" : "mic.circle.fill")
                .frame(maxWidth: .infinity).padding()
        }
        .buttonStyle(.borderedProminent)
        .tint(engine.running ? .red : .indigo)

        Toggle(L("앱을 열면 세션 자동으로 켜기", "Turn session on when the app opens"), isOn: $autoStart).font(.footnote)
        Picker(L("쓰지 않으면 자동으로 끄기", "Turn off when unused"), selection: $idleMinutes) {
            Text(L("1분", "1 min")).tag(1)
            Text(L("3분", "3 min")).tag(3)
            Text(L("5분", "5 min")).tag(5)
            Text(L("15분", "15 min")).tag(15)
            Text(L("30분", "30 min")).tag(30)
        }.font(.footnote)

        if !engine.message.isEmpty { Text(engine.message).font(.footnote) }
        if engine.running {
            Text(engine.recording ? L("듣는 중… ", "Listening… ") + engine.partial
                 : L("여기를 누른 채 말해서 테스트", "Hold here and speak to test") + " (\(testLocale == "en-US" ? "English" : "한국어"))")
                .frame(maxWidth: .infinity).padding()
                .background(engine.recording ? Color.red.opacity(0.3) : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !engine.recording {
                            Bridge.set(testLocale, Bridge.Key.locale)   // 기본 언어 설정을 따른다
                            Bridge.set(String(Date().timeIntervalSince1970), Bridge.Key.startAt)
                            Bridge.post(.start)
                        }
                    }
                    .onEnded { _ in Bridge.post(.stop) })
                .accessibilityAddTraits(.isButton)
        }
        if !engine.lastText.isEmpty { Text(L("마지막 입력: ", "Last result: ") + engine.lastText).font(.callout) }
        Text(L("세션이 켜져 있는 동안 화면 위에 마이크 표시가 보입니다.", "The microphone indicator is shown while the session is on."))
            .font(.caption).foregroundStyle(.secondary)
    }
}
