import AppIntents

/// 동작 버튼·단축어·Siri에서 음성 세션을 켠다. 키보드가 앱을 여는 대신 사용자가 직접 실행한다.
/// 동작 버튼에 연결하는 토글: 누를 때마다 세션을 켜고 끈다.
struct ToggleVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle voice session"
    static var description = IntentDescription("Turns the SnapVoice voice session on if it is off, and off if it is on.")
    // iOS 25 이하: 켜든 끄든 앱이 앞으로 나온다 (켤 때만 나오도록 나눌 수 없다).
    static var openAppWhenRun: Bool = true
    // iOS 26 이상: 평소에는 백그라운드로 실행하고, 앱이 앞에 있어야 하는 "켜기"에서만 앱을 앞으로 가져온다.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @MainActor func perform() async throws -> some IntentResult {
        let engine = DictationEngine.shared
        if engine.running {
            engine.stopSession()   // 끄는 것은 앱을 열지 않고 처리한다
            return .result()
        }
        guard UserDefaults.standard.bool(forKey: "onboarded") else {
            if #available(iOS 26.0, *) { try await continueInForeground(alwaysConfirm: false) }   // 동의 안내를 보여 준다
            return .result()
        }
        // 마이크는 앱이 앞에 있을 때만 새로 켤 수 있다.
        if #available(iOS 26.0, *) { try await continueInForeground(alwaysConfirm: false) }
        engine.startSession()
        return .result()
    }
}

struct StartVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Start voice session"
    static var description = IntentDescription("Turns on the SnapVoice voice session so the keyboard can dictate.")
    static var openAppWhenRun: Bool = true   // 백그라운드에서는 마이크를 새로 켤 수 없어 앱을 앞으로 가져온다

    @MainActor func perform() async throws -> some IntentResult {
        // 첫 실행 동의 전에는 켜지 않는다. 앱 화면의 동의 안내가 보인다.
        if UserDefaults.standard.bool(forKey: "onboarded") { DictationEngine.shared.startSession() }
        return .result()
    }
}

struct StopVoiceSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop voice session"
    static var description = IntentDescription("Turns off the SnapVoice voice session and the microphone.")

    @MainActor func perform() async throws -> some IntentResult {
        DictationEngine.shared.stopSession()
        return .result()
    }
}

struct SnapVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleVoiceSessionIntent(),
                    phrases: ["Toggle voice session in \(.applicationName)"],
                    shortTitle: "Toggle voice session", systemImageName: "mic.circle")
        AppShortcut(intent: StartVoiceSessionIntent(),
                    phrases: ["Start voice session in \(.applicationName)", "Turn on \(.applicationName)"],
                    shortTitle: "Start voice session", systemImageName: "mic.fill")
        AppShortcut(intent: StopVoiceSessionIntent(),
                    phrases: ["Stop voice session in \(.applicationName)", "Turn off \(.applicationName)"],
                    shortTitle: "Stop voice session", systemImageName: "mic.slash.fill")
    }
}
