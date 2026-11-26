import Foundation

/// 기기 언어가 한국어면 ko, 아니면 en 문구를 쓴다.
let isKorean = (Locale.preferredLanguages.first ?? "ko").hasPrefix("ko")
func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

/// 앱 ↔ 키보드 통신: App Group 공유 폴더의 파일 + Darwin 알림
/// (UserDefaults는 프로세스 간 반영이 늦어 알림 직후 읽으면 옛 값이 나온다)
enum Bridge {
    static let group = "group.com.addvalue.snapvoicekeyboard"
    static let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)

    enum Key {
        static let heartbeat = "heartbeat"   // 앱 세션 생존 신호 (timeIntervalSince1970)
        static let partial = "partial"       // 인식 중간 텍스트
        static let final = "final"           // 확정 텍스트
        static let error = "error"           // 실패 사유
        static let startAt = "startAt"       // 시작 신호를 보낸 시각
        static let height = "height"         // 사용자가 정한 키보드 높이(pt)
        static let defaultLang = "defaultLang" // 시작 언어 설정: ko / en / last
        static let metrics = "metrics"       // 키보드 성능 측정 결과(JSON, 디버그 빌드)
        static let metricsReset = "metricsReset"
        static let lang = "lang"             // 키보드 마지막 언어 (ko / en)
        static let locale = "locale"         // 받아쓰기 언어 (ko-KR / en-US)
        static let numberRow = "numberRow"   // 숫자 키 줄 보이기 (1 / 0, 기본 끔)
    }

    enum Event: String {
        case start = "com.addvalue.snapvoicekeyboard.start"     // 키보드 → 앱: 녹음 시작
        case stop = "com.addvalue.snapvoicekeyboard.stop"       // 키보드 → 앱: 녹음 종료
        case partial = "com.addvalue.snapvoicekeyboard.partial" // 앱 → 키보드 (시작 확인 겸용)
        case result = "com.addvalue.snapvoicekeyboard.result"   // 앱 → 키보드
        case config = "com.addvalue.snapvoicekeyboard.config"   // 앱 → 키보드: 설정 변경
    }

    static func set(_ value: String, _ key: String) {
        guard let dir else { return }
        try? value.write(to: dir.appendingPathComponent(key), atomically: true, encoding: .utf8)
    }

    static func get(_ key: String) -> String {
        guard let dir else { return "" }
        return (try? String(contentsOf: dir.appendingPathComponent(key), encoding: .utf8)) ?? ""
    }

    /// 키보드 높이 프리셋 (NativeTone과 같은 작게/보통/크게. 상단 바가 없어 NativeTone 값에서 바 높이 44pt를 뺐다)
    enum HeightPreset: String, CaseIterable {
        case small, medium, large
        var points: Double {
            switch self { case .small: return 202; case .medium: return 232; case .large: return 266 }
        }
        var label: String {
            switch self { case .small: return L("작게", "Small"); case .medium: return L("보통", "Medium"); case .large: return L("크게", "Large") }
        }
    }
    static let defaultHeight = HeightPreset.medium.points

    static var heightPreset: HeightPreset {
        let v = get(Key.height)
        if let p = HeightPreset(rawValue: v) { return p }
        if let n = Double(v) {   // 예전 슬라이더 값은 가장 가까운 프리셋으로
            return HeightPreset.allCases.min { abs($0.points - n) < abs($1.points - n) } ?? .medium
        }
        return .medium
    }
    static var keyboardHeight: Double { heightPreset.points }
    static var showNumberRow: Bool { Bridge.get(Key.numberRow) == "1" }

    static var isSessionAlive: Bool {
        Date().timeIntervalSince1970 - (Double(get(Key.heartbeat)) ?? 0) < 3
    }

    static func post(_ e: Event) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(e.rawValue as CFString), nil, nil, true)
    }

    private static var handlers: [String: () -> Void] = [:]

    static func observe(_ e: Event, _ handler: @escaping () -> Void) {
        // 키보드 화면은 같은 프로세스에서 여러 번 만들어진다. 관찰자는 이벤트당 한 번만 등록하고
        // 처리기만 최신 것으로 바꿔야 결과가 중복 입력되지 않는다.
        let isNew = handlers[e.rawValue] == nil
        handlers[e.rawValue] = handler
        guard isNew else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, name, _, _ in
                guard let raw = name?.rawValue as String? else { return }
                DispatchQueue.main.async { Bridge.handlers[raw]?() }
            },
            e.rawValue as CFString, nil, .deliverImmediately)
    }
}
