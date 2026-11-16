import Foundation

/// 앱 ↔ 키보드 통신: App Group 공유 폴더의 파일 + Darwin 알림
/// (UserDefaults는 프로세스 간 반영이 늦어 알림 직후 읽으면 옛 값이 나온다)
enum Bridge {
    static let group = "group.com.bongsu.snapvoice"
    static let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)

    enum Key {
        static let heartbeat = "heartbeat"   // 앱 세션 생존 신호 (timeIntervalSince1970)
        static let partial = "partial"       // 인식 중간 텍스트
        static let final = "final"           // 확정 텍스트
        static let error = "error"           // 실패 사유
        static let startAt = "startAt"       // 시작 신호를 보낸 시각
        static let locale = "locale"         // 받아쓰기 언어 (ko-KR / en-US)
    }

    enum Event: String {
        case start = "com.bongsu.snapvoice.start"     // 키보드 → 앱: 녹음 시작
        case stop = "com.bongsu.snapvoice.stop"       // 키보드 → 앱: 녹음 종료
        case partial = "com.bongsu.snapvoice.partial" // 앱 → 키보드 (시작 확인 겸용)
        case result = "com.bongsu.snapvoice.result"   // 앱 → 키보드
    }

    static func set(_ value: String, _ key: String) {
        guard let dir else { return }
        try? value.write(to: dir.appendingPathComponent(key), atomically: true, encoding: .utf8)
    }

    static func get(_ key: String) -> String {
        guard let dir else { return "" }
        return (try? String(contentsOf: dir.appendingPathComponent(key), encoding: .utf8)) ?? ""
    }

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
