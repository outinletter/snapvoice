import UIKit
import CoreHaptics

/// 키 햅틱. Core Haptics를 백그라운드 큐에서 돌려 글자 입력을 막지 않고, 연속 타자에서도 겹쳐 울리지 않게 한다.
/// Core Haptics를 쓸 수 없으면 UIKit 햅틱으로 대신한다. (전체 접근 허용이 켜져 있어야 울린다)
final class Haptics {
    static let shared = Haptics()
    private let q = DispatchQueue(label: "snapvoice.haptics", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var pattern: CHHapticPattern?
    private var ready = false
    private var failed = false          // Core Haptics를 못 쓰면 true: 매번 다시 시도하지 않는다
    var enabled = true               // 전체 접근 허용이 꺼져 있으면 false
    private var last = Date.distantPast
    private let fallback = UIImpactFeedbackGenerator(style: .rigid)

    func prepare() {
        guard enabled else { return }
        fallback.prepare()
        q.async { self.failed = false; if !self.ready { self.setup() } }
    }

    private func setup() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { failed = true; return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true            // 소리·오디오 세션을 건드리지 않는다
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak self] in self?.q.async { self?.ready = false; self?.failed = false; self?.setup() } }
            e.stoppedHandler = { [weak self] _ in self?.q.async { self?.ready = false } }
            try e.start()
            let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)], relativeTime: 0)
            pattern = try CHHapticPattern(events: [ev], parameters: [])
            engine = e; ready = true
        } catch { ready = false; failed = true }
    }

    func tap() {
        guard enabled else { return }
        let now = Date()
        guard now.timeIntervalSince(last) > 0.035 else { return }   // 아주 빠른 연타는 건너뛰어 진동이 뭉치지 않게 한다
        last = now
        q.async {
            if !self.ready && !self.failed { self.setup() }
            if self.ready, let e = self.engine, let p = self.pattern {
                do { try e.makePlayer(with: p).start(atTime: CHHapticTimeImmediate); return } catch { self.ready = false; self.failed = true }
            }
            DispatchQueue.main.async { self.fallback.impactOccurred(intensity: 0.55) }
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private enum Layer { case korean, english, number, symbol }

    // 시작 언어는 앱의 "기본 언어" 설정을 따른다(기본값 한글). "마지막 사용" 선택 시 마지막에 쓴 언어로 시작한다.
    private var layer: Layer = .korean
    private var lastLetter: Layer = .korean
    private var savedLetter: Layer { Bridge.get(Bridge.Key.lang) == "en" ? .english : .korean }
    private var shift = 0                 // 0 꺼짐, 1 한 번, 2 고정
    private var lastShiftTap = Date.distantPast
    private var composer = HangulComposer()

    private let talkTitle = L("누르고 말하기", "Hold to talk")
    private let canvas = KeyCanvas()
    private var holding = false
    private var acked = false
    private var pressID = 0
    private var waiting = false      // 손을 뗀 뒤 결과를 기다리는 중
    private var repeatTimer: Timer?

    private let koRows = ["ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", "ㅁㄴㅇㄹㅎㅗㅓㅏㅣ", "ㅋㅌㅊㅍㅠㅜㅡ"]
    private let koShift = ["ㅃㅉㄸㄲㅆㅛㅕㅑㅒㅖ", "ㅁㄴㅇㄹㅎㅗㅓㅏㅣ", "ㅋㅌㅊㅍㅠㅜㅡ"]
    private let enRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private let numRows = ["1234567890", "-/:;()₩&@\"", ".,?!'"]
    private let symRows = ["[]{}#%^*+=", "_\\|~<>$£¥•", ".,?!'"]

    // MARK: 구성
    override func viewDidLoad() {
        super.viewDidLoad()

        view.isMultipleTouchEnabled = true
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        canvas.onDown = { [weak self] id in self?.keyDown(id) }
        canvas.onUp = { [weak self] id, inside in self?.keyUp(id, inside) }
        canvas.onGlobe = { [weak self] b in
            guard let self else { return }
            b.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        rebuild()

        Bridge.observe(.partial) { [weak self] in
            guard let self, self.holding else { return }
            self.acked = true
            let t = Bridge.get(Bridge.Key.partial)
            self.setTalk(t.isEmpty ? L("듣는 중…", "Listening…") : t)
        }
        Bridge.observe(.result) { [weak self] in self?.finishDictation() }
        Bridge.observe(.config) { [weak self] in self?.applyHeight() }
    }

    private var heightC: NSLayoutConstraint?
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if heightC == nil {
            let c = view.heightAnchor.constraint(equalToConstant: Bridge.defaultHeight)
            c.priority = .init(999); c.isActive = true; heightC = c
        }
        applyHeight()
        // 입력칸 종류에 맞는 자판으로 시작한다
        switch textDocumentProxy.keyboardType {
        case .emailAddress, .URL, .asciiCapable, .twitter: lastLetter = .english; layer = .english
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: layer = .number
        default:
            switch Bridge.get(Bridge.Key.defaultLang) {
            case "en": lastLetter = .english
            case "last": lastLetter = savedLetter
            default: lastLetter = .korean   // 설정이 없으면 한글
            }
            layer = lastLetter
        }
        composer.reset()
        rebuild()   // 지구본 키 필요 여부도 여기서 다시 판단한다
        Haptics.shared.enabled = hasFullAccess   // 전체 접근이 없으면 진동을 시도하지 않는다
        Haptics.shared.prepare()
    }

    /// 앱에서 정한 높이를 반영한다. 가로 모드에서는 화면을 덜 가리도록 낮춘다.
    private func applyHeight() {
        let b = UIScreen.main.bounds
        heightC?.constant = b.width > b.height ? min(Bridge.keyboardHeight, 162) : Bridge.keyboardHeight
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.applyHeight() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // iOS는 화면 가장자리 제스처를 가리려고 터치 시작을 늦춘다. 끄지 않으면 가장자리 키가 굼뜨다.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        Haptics.shared.prepare()
        if !hasFullAccess { setTalk(L("전체 접근을 켜 주세요", "Turn on Full Access"), revert: true) }   // 햅틱·받아쓰기에 필요
    }

    private func rebuild() {
        let rows: [String]
        switch layer {
        case .korean: rows = shift > 0 ? koShift : koRows
        case .english: rows = shift > 0 ? enRows.map { $0.uppercased() } : enRows
        case .number: rows = numRows
        case .symbol: rows = symRows
        }
        func letters(_ s: String, lastGap: CGFloat = 6) -> [KeySpec] {
            let chars = Array(s)
            return chars.enumerated().map { i, ch in
                var k = KeySpec(id: .letter(String(ch)), title: String(ch))
                if i == chars.count - 1 { k.gapAfter = lastGap }
                return k
            }
        }
        let isLetters = layer == .korean || layer == .english
        var specs: [[KeySpec]] = [letters(rows[0]), letters(rows[1])]
        let inset2 = rows[1].count < 10 && isLetters

        // 3행: [모드키] 글자들 [삭제]
        var left: KeySpec
        if layer == .number || layer == .symbol {
            left = KeySpec(id: .symbols, title: layer == .number ? "#+=" : "123", style: .fn, fontSize: 15, width: 45, gapAfter: 14)
        } else {
            let name = shift == 2 ? "capslock.fill" : (shift == 1 ? "shift.fill" : "shift")
            let label = shift == 2 ? L("쉬프트 고정", "Caps Lock") : (shift == 1 ? L("쉬프트 켜짐", "Shift on") : L("쉬프트", "Shift"))
            left = KeySpec(id: .shift, symbol: name, style: .fn, width: 45, gapAfter: 14, label: label)
        }
        let del = KeySpec(id: .delete, symbol: "delete.left", style: .fn, width: 45, label: L("삭제", "Delete"))
        specs.append([left] + letters(rows[2], lastGap: 14) + [del])

        // 4행: [123] [지구본] [한/A] [누르고 말하기] [space] [return]
        var r4: [KeySpec] = [KeySpec(id: .mode, title: isLetters ? "123" : (lastLetter == .korean ? "가" : "ABC"), style: .fn, fontSize: 18, width: 56,
                                     label: isLetters ? L("숫자", "Numbers") : L("글자", "Letters"))]
        if needsInputModeSwitchKey {   // 홈 버튼 기기에서만 자체 지구본 표시
            r4.append(KeySpec(id: .globe, symbol: "globe", style: .fn, width: 44, label: L("다음 키보드", "Next keyboard")))
        }
        r4.append(KeySpec(id: .lang, title: lastLetter == .korean ? "한" : "A", style: .fn, fontSize: 18, width: 44,
                          label: L("한영 전환", "Switch language"), value: lastLetter == .korean ? L("한글", "Korean") : L("영어", "English")))
        r4.append(KeySpec(id: .talk, title: talkTitle, symbol: "mic.fill", style: .accent, fontSize: 13,
                          label: L("누르고 말하기", "Hold to talk"), hint: L("누르고 있는 동안 말하면 글자로 입력됩니다", "Speak while holding to insert text")))
        r4.append(KeySpec(id: .space, title: "space", fontSize: 15, titleColor: .secondaryLabel, label: L("스페이스", "Space")))
        r4.append(KeySpec(id: .ret, symbol: "return", style: .accent, width: 56, label: L("줄바꿈", "Return")))
        specs.append(r4)

        canvas.insetRows = [false, inset2, false, false]
        canvas.rows = specs
    }

    // MARK: 키 입력 (터치 순간 / 뗄 때)
    private func keyDown(_ id: KeyID) {
        switch id {
        case .letter(let s): typeLetter(s)
        case .delete: startDelete()
        case .space: composer.reset(); textDocumentProxy.insertText(" ")
        case .ret: composer.reset(); textDocumentProxy.insertText("\n")
        case .talk: talkDown()
        default: break
        }
    }

    private func keyUp(_ id: KeyID, _ inside: Bool) {
        switch id {
        case .delete: stopDelete()
        case .talk: talkUp()
        case .shift where inside: tapShift()
        case .symbols where inside: layer = layer == .number ? .symbol : .number; rebuild()
        case .mode where inside:
            composer.reset()
            layer = (layer == .korean || layer == .english) ? .number : lastLetter
            rebuild()
        case .lang where inside: toggleLanguage()
        default: break
        }
    }

    private func setTalkIcon(_ name: String) { canvas.update(.talk, symbol: .some(name)) }

    private func setTalk(_ t: String, revert: Bool = false, icon: String? = nil) {
        canvas.update(.talk, title: t, symbol: icon.map { .some($0) })
        if revert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.holding else { return }
                self.canvas.update(.talk, title: self.talkTitle, symbol: .some("mic.fill"))
            }
        }
    }

    // MARK: 입력
    private var lastKeyAt = Date.distantPast
    private func syncComposer() {
        // 입력창을 읽는 것은 느리다. 빠르게 이어 칠 때는 건너뛰고, 잠시 쉬었다 칠 때만 커서 이동을 확인한다.
        let now = Date(); defer { lastKeyAt = now }
        guard now.timeIntervalSince(lastKeyAt) > 0.8 else { return }
        guard composer.isComposing, let before = textDocumentProxy.documentContextBeforeInput else { return }
        if before.last.map({ String($0) }) != composer.text { composer.reset() }
    }

    private func apply(_ e: HangulComposer.Edit) {
        if e.delete { textDocumentProxy.deleteBackward() }
        if !e.insert.isEmpty { textDocumentProxy.insertText(e.insert) }
    }

    private func typeLetter(_ s: String) {
        if layer == .korean, let ch = s.first {
            if composer.isComposing { syncComposer() } else { lastKeyAt = Date() }
            apply(composer.input(ch))
        } else {
            composer.reset(); textDocumentProxy.insertText(s)
        }
        if shift == 1 { shift = 0; rebuild() }
    }

    private func tapShift() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.4 { shift = 2 } else { shift = shift == 0 ? 1 : 0 }
        lastShiftTap = now
        rebuild()
    }

    private func deleteOnce() {
        syncComposer()
        if let e = composer.backspace() { apply(e) } else { textDocumentProxy.deleteBackward() }
    }

    private func startDelete() {
        deleteOnce()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self?.deleteOnce() }
        }
    }
    private func stopDelete() { repeatTimer?.invalidate(); repeatTimer = nil }

    // MARK: 음성
    private func toggleLanguage() {
        composer.reset()
        lastLetter = lastLetter == .korean ? .english : .korean
        layer = lastLetter; shift = 0
        Bridge.set(lastLetter == .korean ? "ko" : "en", Bridge.Key.lang)
        rebuild()
    }

    private func talkDown() {
        guard hasFullAccess else { setTalk(L("전체 접근 허용 필요", "Allow Full Access"), revert: true); return }
        guard Bridge.isSessionAlive else {
            setTalk(L("세션 꺼짐", "Session off"), revert: true, icon: "mic.slash.fill")   // 키보드는 다른 앱을 열지 않는다(4.4.1)
            return
        }
        holding = true; acked = false; pressID += 1
        Bridge.set(String(Date().timeIntervalSince1970), Bridge.Key.startAt)
        Bridge.set(lastLetter == .korean ? "ko-KR" : "en-US", Bridge.Key.locale)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.holding, !self.acked else { return }
            self.setTalk(L("앱 응답 없음", "No response"))
        }
        setTalk(L("연결 중…", "Connecting…"))
        canvas.update(.talk, fill: .some(UIColor.systemRed))
        Bridge.post(.start)
    }

    private func talkUp() {
        guard holding else { return }
        holding = false; waiting = true
        setTalk(L("변환 중…", "Transcribing…"))
        let id = pressID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pressID == id, !self.holding, self.waiting else { return }
            self.waiting = false
            self.setTalk(L("앱 응답 없음", "No response"), revert: true)
        }
        canvas.update(.talk, fill: .some(nil))
        Bridge.post(.stop)
    }

    private func finishDictation() {
        guard waiting || holding else { return }   // 기다리지 않는 결과는 무시
        waiting = false
        if holding { holding = false; canvas.update(.talk, fill: .some(nil)) }
        let text = Bridge.get(Bridge.Key.final)
        let err = Bridge.get(Bridge.Key.error)
        setTalk(text.isEmpty ? (err.isEmpty ? L("인식 없음", "Nothing heard") : err) : L("입력됨", "Inserted"), revert: true)
        if !text.isEmpty { composer.reset(); textDocumentProxy.insertText(text + " ") }   // 다음 받아쓰기와 띄어지도록 끝에 공백
    }
}
