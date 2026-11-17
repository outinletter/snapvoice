import AVFoundation
import Speech
import UIKit

/// 백그라운드에서 마이크를 유지하다가 키보드 신호에 맞춰 받아쓰기한다.
final class DictationEngine: ObservableObject {
    @Published var running = false
    @Published var recording = false
    @Published var partial = ""
    @Published var lastText = ""
    @Published var message = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var latest = ""
    private var generation = 0      // 녹음 회차. 늦게 도착한 이전 회차 콜백을 무시한다
    private var delivered = true
    private var lastActivity = Date()   // 마지막으로 받아쓴 시각. 오래 안 쓰면 세션을 끈다
    private static var onMessage: String { L("세션 켜짐. 다른 앱으로 이동해 키보드를 사용하세요.", "Session on. Switch to another app and use the keyboard.") }

    /// 자동 종료까지의 분. 0이면 끄지 않는다.
    static var idleMinutes: Int {
        UserDefaults.standard.object(forKey: "idleMinutes") == nil ? 15 : UserDefaults.standard.integer(forKey: "idleMinutes")
    }

    init() {
        Bridge.observe(.start) { [weak self] in self?.beginRecording() }
        Bridge.observe(.stop) { [weak self] in self?.endRecording() }

        // 전화·화면 녹화·경로 변경 등으로 마이크가 끊기면 앱이 곧 일시 중지된다. 끊길 때마다 다시 켠다.
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw == AVAudioSession.InterruptionType.ended.rawValue { self?.ensureAudio() }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.ensureAudio() }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in self?.ensureAudio() }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            if self.recording { self.cancelRecording() }   // 일시 중지 중 밀린 신호로 걸린 상태 해제
            self.ensureAudio()
            self.beat()
        }
    }

    /// 마이크 입력을 (다시) 켠다. 엔진이 돌고 있으면 그대로 둔다.
    private func activate() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try s.setActive(true)
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { throw NSError(domain: "SnapVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: L("마이크 입력 없음", "No microphone input")]) }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        try engine.start()
    }

    @discardableResult private func ensureAudio() -> Bool {
        guard running else { return false }
        if engine.isRunning { return true }
        do { try activate(); message = Self.onMessage; return true }
        catch { message = L("마이크가 끊겼습니다. 앱을 열어 두면 다시 연결합니다.", "Microphone was interrupted. Keep the app open to reconnect."); return false }
    }

    private func cancelRecording() {
        generation += 1
        task?.cancel(); task = nil; request = nil
        recording = false; delivered = true; partial = ""
    }

    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { s in
            AVAudioApplication.requestRecordPermission { m in
                DispatchQueue.main.async { done(s == .authorized && m) }
            }
        }
    }

    func startSession() {
        guard !running else { return }
        requestPermissions { [weak self] ok in
            guard let self, ok else { self?.message = L("마이크·음성 인식 권한을 허용해 주세요.", "Please allow Microphone and Speech Recognition access."); return }
            guard !self.running else { return }
            do {
                try self.activate()
                self.running = true
                self.message = Self.onMessage
                self.lastActivity = Date()
                self.beat()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.beat() }
            } catch {
                self.message = L("시작 실패: ", "Could not start: ") + error.localizedDescription
            }
        }
    }

    func stopSession() {
        timer?.invalidate(); timer = nil
        generation += 1
        task?.cancel(); task = nil; request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        Bridge.set("0", Bridge.Key.heartbeat)
        running = false; recording = false
        message = L("세션 꺼짐", "Session off")
    }

    private func beat() {
        let idle = Self.idleMinutes
        if idle > 0, !recording, Date().timeIntervalSince(lastActivity) > Double(idle * 60) {
            stopSession()
            message = L("\(idle)분 동안 쓰지 않아 세션을 껐습니다. 앱을 다시 열면 켜집니다.", "Session turned off after \(idle) min of inactivity. Reopen the app to turn it on.")
            return
        }
        // 마이크가 실제로 돌고 있을 때만 생존 신호를 쓴다. 끊겼으면 키보드가 앱을 다시 연다.
        guard ensureAudio() else { return }
        Bridge.set(String(Date().timeIntervalSince1970), Bridge.Key.heartbeat)
    }

    private func fail(_ reason: String) {
        message = reason
        Bridge.set("", Bridge.Key.final)
        Bridge.set(reason, Bridge.Key.error)
        Bridge.post(.result)
    }

    private func beginRecording() {
        guard running else { return }
        // 앱이 멈춰 있던 동안 밀린 오래된 시작 신호는 버린다
        guard Date().timeIntervalSince1970 - (Double(Bridge.get(Bridge.Key.startAt)) ?? 0) < 2 else { return }
        if recording { cancelRecording() }
        lastActivity = Date()
        generation += 1
        let gen = generation
        task?.cancel(); task = nil
        latest = ""; partial = ""; delivered = false
        Bridge.set("", Bridge.Key.partial)
        Bridge.set("", Bridge.Key.final)
        Bridge.set("", Bridge.Key.error)

        var loc = Bridge.get(Bridge.Key.locale)
        if loc.isEmpty { loc = "ko-KR" }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: loc)) else {
            return fail(L("\(loc) 음성 인식을 지원하지 않음", "Speech recognition not supported for \(loc)"))
        }
        guard recognizer.isAvailable else { return fail(L("음성 인식을 지금 쓸 수 없음", "Speech recognition unavailable")) }
        guard ensureAudio() else { return fail(L("마이크 끊김. 앱을 여세요", "Mic lost. Open the app")) }

        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        request = r
        recording = true
        task = recognizer.recognitionTask(with: r) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.partial = self.latest
                    Bridge.set(self.latest, Bridge.Key.partial)
                    Bridge.post(.partial)
                    if result.isFinal { self.deliver(gen) }
                } else if let error {
                    if self.latest.isEmpty && self.recording {
                        self.recording = false; self.request = nil
                        self.delivered = true
                        self.fail(L("인식 실패", "Recognition failed"))
                    } else { self.deliver(gen) }
                }
            }
        }
        Bridge.post(.partial)   // 키보드에 "시작됨" 확인
    }

    private func endRecording() {
        guard recording else { return }
        recording = false
        lastActivity = Date()
        let gen = generation
        request?.endAudio()
        // 최종 결과가 늦으면 중간 결과로 전달
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.deliver(gen) }
    }

    private func deliver(_ gen: Int) {
        guard gen == generation, !delivered else { return }
        if recording { return }   // 아직 누르고 있는 중이면 손을 뗄 때 전달
        delivered = true
        task?.cancel(); task = nil; request = nil
        lastText = latest
        Bridge.set(latest, Bridge.Key.final)
        Bridge.post(.result)
    }
}
