import UIKit
import CoreHaptics

/// 키 햅틱. Core Haptics를 백그라운드 큐에서 돌려 글자 입력을 막지 않고, 키마다 짧고 약하게 울린다(연타도 생략하지 않음).
/// Core Haptics를 쓸 수 없으면 UIKit 햅틱으로 대신한다. (전체 접근 허용이 켜져 있어야 울린다)
final class Haptics {
    static let shared = Haptics()
    private let q = DispatchQueue(label: "snapvoice.haptics", qos: .userInteractive)
    private var engine: CHHapticEngine?
    private var pattern: CHHapticPattern?
    private var ready = false
    private var failed = false          // Core Haptics를 못 쓰면 true: 매번 다시 시도하지 않는다
    var enabled = true               // 전체 접근 허용이 꺼져 있으면 false
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
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)], relativeTime: 0)
            pattern = try CHHapticPattern(events: [ev], parameters: [])
            engine = e; ready = true
        } catch { ready = false; failed = true }
    }

    func tap() {
        guard enabled else { return }
        q.async {
            if !self.ready && !self.failed { self.setup() }
            if self.ready, let e = self.engine, let p = self.pattern {
                do { try e.makePlayer(with: p).start(atTime: CHHapticTimeImmediate); return } catch { self.ready = false; self.failed = true }
            }
            DispatchQueue.main.async { self.fallback.impactOccurred(intensity: 0.35) }
        }
    }
}

final class KeyboardViewController: UIInputViewController {
    private enum Layer { case korean, english, number, symbol }

    // NativeTone 키보드 구조를 바탕으로 한다: 키마다 버튼, 손가락을 뗄 때 입력, 상단 바 없음, 누르고 말하기 키 추가
    private var layer: Layer = .korean
    private var lastLetter: Layer = .korean
    private var savedLetter: Layer { Bridge.get(Bridge.Key.lang) == "en" ? .english : .korean }
    private var shifted = false
    private var capsLock = false
    private var lastShiftTap = Date.distantPast
    private var composer = HangulComposer()

    private let keysStack = UIStackView()
    private var letterBases: [(KeyButton, String)] = []
    private var shiftButton: KeyButton?
    private var talk: KeyButton?
    private let talkTitle = L("누르고 말하기", "Hold to talk")
    private var holding = false
    private var acked = false
    private var pressID = 0
    private var waiting = false      // 손을 뗀 뒤 결과를 기다리는 중

    private static let shiftedJamo: [String: String] = [
        "ㅂ": "ㅃ", "ㅈ": "ㅉ", "ㄷ": "ㄸ", "ㄱ": "ㄲ", "ㅅ": "ㅆ", "ㅐ": "ㅒ", "ㅔ": "ㅖ",
    ]

    // MARK: 생명주기
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KeyboardTheme.background
        KeyButton.popupHost = view

        keysStack.axis = .vertical
        keysStack.spacing = Self.rowGap
        keysStack.distribution = .fillEqually
        keysStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keysStack)
        NSLayoutConstraint.activate([
            keysStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            keysStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            keysStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            keysStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
        rebuildKeys()

        Bridge.observe(.partial) { [weak self] in
            guard let self, self.holding else { return }
            self.acked = true
            let t = Bridge.get(Bridge.Key.partial)
            self.setTalk(t.isEmpty ? L("듣는 중…", "Listening…") : t)
        }
        Bridge.observe(.result) { [weak self] in self?.finishDictation() }
        Bridge.observe(.config) { [weak self] in self?.rebuildKeys(); self?.applyHeight() }
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
        shifted = false; capsLock = false
        rebuildKeys()   // 지구본 키 필요 여부도 여기서 다시 판단한다
        Haptics.shared.enabled = hasFullAccess
        Haptics.shared.prepare()
    }

    /// 앱에서 정한 높이를 반영한다. 가로 모드에서는 화면을 덜 가리도록 낮춘다.
    private func applyHeight() {
        let b = UIScreen.main.bounds
        let base = b.width > b.height ? min(Bridge.keyboardHeight, 162) : Bridge.keyboardHeight
        guard showsNumberRow else { heightC?.constant = base; return }
        // 글자 줄 크기는 그대로 두고 숫자 줄(글자 줄의 80%)과 줄 간격만큼 더한다. 4줄 + 간격 3개 + 위아래 여백 12pt
        let rowHeight = (base - 12 - 3 * Self.rowGap) / 4
        heightC?.constant = base + rowHeight * Self.numberRowScale + Self.rowGap
    }

    private static let rowGap: CGFloat = 10
    private static let numberRowScale: CGFloat = 0.8
    /// 숫자 키 줄은 한글·영어 자판 위에만 둔다(숫자·기호 자판에는 없음)
    private var showsNumberRow: Bool { Bridge.showNumberRow && (layer == .korean || layer == .english) }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.applyHeight() }
    }

    #if DEBUG
    private var frameLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    @objc private func frameTick(_ l: CADisplayLink) {
        let dt = (l.timestamp - lastFrame) * 1000
        if lastFrame > 0 {
            Metrics.shared.bump("frames")
            if dt > 25 { Metrics.shared.record("frame.gap", dt) }   // 화면이 25ms 넘게 멈춘 경우
        }
        lastFrame = l.timestamp
    }
    #endif

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushPending()
        #if DEBUG
        frameLink?.invalidate(); frameLink = nil; lastFrame = 0
        Metrics.shared.flush(force: true)
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        #if DEBUG
        frameLink?.invalidate()
        frameLink = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        frameLink?.add(to: .main, forMode: .common)
        Metrics.shared.meta = ["fullAccess": hasFullAccess ? "on" : "off", "session": Bridge.isSessionAlive ? "on" : "off", "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"]
        #endif
        super.viewDidAppear(animated)
        // iOS는 화면 가장자리 제스처를 가리려고 터치 시작을 늦춘다. 끄지 않으면 가장자리 키가 굼뜨다.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        Haptics.shared.prepare()
        if !hasFullAccess { setTalk(L("전체 접근을 켜 주세요", "Turn on Full Access"), revert: true) }   // 햅틱·받아쓰기에 필요
    }

    // MARK: 키 배치 (NativeTone과 같은 구조)
    private func rebuildKeys() {
        keysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        letterBases = []; shiftButton = nil; talk = nil

        let rows: [[String]]
        switch layer {
        case .korean: rows = ["ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ", "ㅁㄴㅇㄹㅎㅗㅓㅏㅣ", "ㅋㅌㅊㅍㅠㅜㅡ"].map { Array($0).map(String.init) }
        case .english: rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0).map(String.init) }
        case .number: rows = [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "₩", "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbol: rows = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "$", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        }
        let isLetters = layer == .korean || layer == .english
        keysStack.distribution = .fillEqually

        // 숫자 키 줄(설정에서 켰을 때)
        var digits: UIStackView?
        if showsNumberRow {
            let d = UIStackView()
            d.axis = .horizontal; d.spacing = 5; d.distribution = .fillEqually
            let k = Array("1234567890").map { makeCharKey(String($0)) }
            k.forEach { $0.popupAbove = false; d.addArrangedSubview($0) }
            keysStack.addArrangedSubview(d)
            digits = d
        }

        // 1행: 기준 키 폭
        let row1 = UIStackView()
        row1.axis = .horizontal; row1.spacing = 5; row1.distribution = .fillEqually
        let row1Keys = rows[0].map(makeCharKey)
        if digits == nil { row1Keys.forEach { $0.popupAbove = false } }   // 맨 윗줄은 위 공간이 없다
        row1Keys.forEach(row1.addArrangedSubview)
        keysStack.addArrangedSubview(row1)
        let ref = row1Keys[0]

        // 2행: 가운데 정렬, 1행 키와 같은 폭
        let row2Keys = rows[1].map(makeCharKey)
        keysStack.addArrangedSubview(centeredRow(row2Keys))
        row2Keys.forEach { $0.widthAnchor.constraint(equalTo: ref.widthAnchor).isActive = true }

        // 3행: [쉬프트/기호] 글자들 [삭제]
        let leftSpecial: KeyButton
        if isLetters {
            leftSpecial = KeyButton(symbol: "shift", style: .special)
            leftSpecial.accessibilityLabel = L("쉬프트", "Shift")
            leftSpecial.onTap = { [weak self] in self?.tapShift() }
            shiftButton = leftSpecial
        } else {
            leftSpecial = KeyButton(title: layer == .number ? "#+=" : "123", style: .special, fontSize: 16)
            leftSpecial.onTap = { [weak self] in
                guard let self else { return }
                self.layer = self.layer == .number ? .symbol : .number; self.rebuildKeys()
            }
        }
        let delete = KeyButton(symbol: "delete.left", style: .special)
        delete.accessibilityLabel = L("삭제", "Delete")
        delete.onRepeat = { [weak self] in self?.backspace() }
        let row3Keys = rows[2].map(makeCharKey)
        let row3 = UIStackView(arrangedSubviews: [leftSpecial] + row3Keys + [delete])
        row3.axis = .horizontal; row3.spacing = 5; row3.distribution = .fill
        keysStack.addArrangedSubview(row3)
        leftSpecial.widthAnchor.constraint(equalTo: delete.widthAnchor).isActive = true
        if isLetters {
            row3Keys.forEach { $0.widthAnchor.constraint(equalTo: ref.widthAnchor).isActive = true }
        } else {
            leftSpecial.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 1.5).isActive = true
            for k in row3Keys.dropFirst() { k.widthAnchor.constraint(equalTo: row3Keys[0].widthAnchor).isActive = true }
        }

        // 4행: [123/가·ABC] [지구본] [한/A] [누르고 말하기] [space] [return]
        let letterTitle = lastLetter == .korean ? "가나다" : "ABC"
        let modeKey = KeyButton(title: isLetters ? "123" : letterTitle, style: .special, fontSize: 16)
        modeKey.accessibilityLabel = isLetters ? L("숫자", "Numbers") : L("글자", "Letters")
        modeKey.onTap = { [weak self] in
            guard let self else { return }
            self.composer.reset()
            self.layer = (self.layer == .korean || self.layer == .english) ? .number : self.lastLetter
            self.rebuildKeys()
        }
        let langKey = KeyButton(title: lastLetter == .korean ? "EN" : "한", style: .special, fontSize: 16)
        langKey.accessibilityLabel = L("한영 전환", "Switch language")
        langKey.onTap = { [weak self] in self?.toggleLanguage() }
        let voice = KeyButton(title: talkTitle, symbol: "mic.fill", style: .voice, fontSize: 13)
        voice.accessibilityLabel = L("누르고 말하기", "Hold to talk")
        voice.accessibilityHint = L("누르고 있는 동안 말하면 글자로 입력됩니다", "Speak while holding to insert text")
        voice.titleLabel?.numberOfLines = 2
        voice.titleLabel?.textAlignment = .center
        voice.titleLabel?.lineBreakMode = .byTruncatingHead
        voice.imageEdgeInsets = UIEdgeInsets(top: 0, left: -2, bottom: 0, right: 2)
        voice.onDown = { [weak self] in self?.talkDown() }
        voice.onUp = { [weak self] in self?.talkUp() }
        talk = voice
        let space = KeyButton(title: lastLetter == .korean ? "간격" : "space", style: .letter, fontSize: 16)
        space.accessibilityLabel = L("스페이스", "Space")
        space.onTap = { [weak self] in self?.composer.reset(); self?.hostInsert(" ") }
        let ret = KeyButton(title: "return", style: .special, fontSize: 16)
        ret.accessibilityLabel = L("줄바꿈", "Return")
        ret.onTap = { [weak self] in self?.composer.reset(); self?.hostInsertNow("\n") }

        var bottomKeys = [modeKey]
        if needsInputModeSwitchKey {   // 홈 버튼 기기에서만 자체 지구본 표시
            let globe = KeyButton(symbol: "globe", style: .special)
            globe.accessibilityLabel = L("다음 키보드", "Next keyboard")
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            bottomKeys.append(globe)
        }
        let bottom = UIStackView(arrangedSubviews: bottomKeys + [langKey, voice, space, ret])
        bottom.axis = .horizontal; bottom.spacing = 5; bottom.distribution = .fill
        keysStack.addArrangedSubview(bottom)
        if let digits {
            // 글자 줄은 같은 높이, 숫자 줄은 그 80%
            keysStack.distribution = .fill
            let rows = keysStack.arrangedSubviews.filter { $0 !== digits }
            rows.dropFirst().forEach { $0.heightAnchor.constraint(equalTo: rows[0].heightAnchor).isActive = true }
            digits.heightAnchor.constraint(equalTo: rows[0].heightAnchor, multiplier: Self.numberRowScale).isActive = true
        }
        applyHeight()
        modeKey.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 1.4).isActive = true
        bottomKeys.dropFirst().forEach { $0.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 1.2).isActive = true }
        langKey.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 1.2).isActive = true
        ret.widthAnchor.constraint(equalTo: ref.widthAnchor, multiplier: 2.2).isActive = true
        voice.widthAnchor.constraint(equalTo: space.widthAnchor).isActive = true

        refreshLetters()
    }

    private func makeCharKey(_ ch: String) -> KeyButton {
        let b = KeyButton(title: ch, style: .letter)
        b.onTap = { [weak self, weak b] in
            guard let self else { return }
            self.type(b?.title(for: .normal) ?? ch)
        }
        if (layer == .korean || layer == .english) && !ch.allSatisfy(\.isNumber) { letterBases.append((b, ch)) }
        return b
    }

    private func centeredRow(_ keys: [KeyButton]) -> UIView {
        let container = UIView()
        let stack = UIStackView(arrangedSubviews: keys)
        stack.axis = .horizontal; stack.spacing = 5; stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: 입력

    // 입력창 앱으로 보내는 요청을 줄인다. 영어는 아주 빠른 연타(12ms 이내)를 한 번에 합쳐서 보낸다.
    // 합치는 동안에도 다른 요청(삭제, 읽기, 한글 조합)은 먼저 밀린 글자를 내보내 순서를 지킨다.
    private var pendingText = ""
    private var pendingDelete = 0            // 입력창에서 지워야 할 글자 수 (밀린 글자보다 앞에서 지운다)
    private var lastSend = Date.distantPast
    private var flushScheduled = false

    private func flushPending() {
        guard pendingDelete > 0 || !pendingText.isEmpty else { return }
        let n = pendingDelete, t = pendingText
        pendingDelete = 0; pendingText = ""
        lastSend = Date()
        for _ in 0..<n { Metrics.shared.time("proxy.delete") { textDocumentProxy.deleteBackward() } }
        if !t.isEmpty { Metrics.shared.time("proxy.insert") { textDocumentProxy.insertText(t) } }
    }

    /// 터치 처리가 끝난 뒤(다음 런루프), 직전 전송 후 12ms가 지나면 바로, 아니면 그때까지 기다렸다가 한 번에 보낸다.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, 0.012 - Date().timeIntervalSince(lastSend))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.flushScheduled = false
            self?.flushPending()
        }
    }

    private func hostInsert(_ s: String) {          // 합칠 수 있는 입력 (영어 글자, 스페이스)
        pendingText += s
        scheduleFlush()
    }

    private func hostInsertNow(_ s: String) {       // 바로 보내야 하는 입력 (줄바꿈, 받아쓰기 결과)
        pendingText += s
        flushPending()
    }

    private func hostDelete() {                     // 밀린 글자가 있으면 그 글자를 지운 것으로 합친다
        if pendingText.isEmpty { pendingDelete += 1 } else { pendingText.removeLast() }
        scheduleFlush()
    }

    private func hostRead() -> String? {
        flushPending()
        return Metrics.shared.time("proxy.read") { textDocumentProxy.documentContextBeforeInput }
    }

    private var lastKeyAt = Date.distantPast
    private func syncComposer() {
        // 입력창을 읽는 것은 느리다. 빠르게 이어 칠 때는 건너뛰고, 잠시 쉬었다 칠 때만 커서 이동을 확인한다.
        let now = Date(); defer { lastKeyAt = now }
        guard now.timeIntervalSince(lastKeyAt) > 0.8 else { return }
        guard composer.isComposing, let before = hostRead() else { return }
        if before.last.map({ String($0) }) != composer.text { composer.reset() }
    }

    private func apply(_ e: HangulComposer.Edit) {
        if e.delete { hostDelete() }
        if !e.insert.isEmpty { hostInsert(e.insert) }
    }

    private var lastTypeAt = CACurrentMediaTime()
    private func type(_ s: String) {
        let kor = layer == .korean
        Metrics.shared.time((kor ? "ko" : "en") + ".type") {
            if kor, let ch = s.first, ch.isLetter {   // 숫자 키 줄의 숫자는 조합하지 않는다
                if composer.isComposing { syncComposer() } else { lastKeyAt = Date() }
                apply(composer.input(ch))
            } else {
                composer.reset(); hostInsert(s)
            }
            if shifted && !capsLock { shifted = false; refreshLetters() }
        }
        let now = CACurrentMediaTime()
        if now - lastTypeAt < 1.5 { Metrics.shared.record("key.interval", (now - lastTypeAt) * 1000) }
        lastTypeAt = now
    }

    private func backspace() {
        syncComposer()
        if let e = composer.backspace() { apply(e) } else { hostDelete() }
    }

    private func displayTitle(_ base: String) -> String {
        if layer == .korean { return shifted ? (Self.shiftedJamo[base] ?? base) : base }
        return shifted ? base.uppercased() : base
    }

    private func refreshLetters() {
        for (b, base) in letterBases { b.setTitle(displayTitle(base), for: .normal) }
        shiftButton?.setActive(shifted)
        shiftButton?.setSymbol(capsLock ? "capslock.fill" : (shifted ? "shift.fill" : "shift"))
        shiftButton?.accessibilityLabel = capsLock ? L("쉬프트 고정", "Caps Lock") : (shifted ? L("쉬프트 켜짐", "Shift on") : L("쉬프트", "Shift"))
    }

    private func tapShift() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.35 {
            capsLock = true; shifted = true
        } else if capsLock {
            capsLock = false; shifted = false
        } else {
            shifted.toggle()
        }
        lastShiftTap = now
        refreshLetters()
    }

    private func toggleLanguage() {
        flushPending()
        composer.reset()
        lastLetter = lastLetter == .korean ? .english : .korean
        layer = lastLetter
        shifted = false; capsLock = false
        Bridge.set(lastLetter == .korean ? "ko" : "en", Bridge.Key.lang)
        rebuildKeys()
    }

    // MARK: 음성
    private func setTalk(_ t: String, revert: Bool = false, icon: String? = nil) {
        talk?.setTitle(t, for: .normal)
        if let icon { talk?.setSymbol(icon, size: 13) }
        if revert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.holding else { return }
                self.talk?.setTitle(self.talkTitle, for: .normal)
                self.talk?.setSymbol("mic.fill", size: 13)
            }
        }
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
        talk?.setRecording(true)
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
        talk?.setRecording(false)
        Bridge.post(.stop)
    }

    private func finishDictation() {
        guard waiting || holding else { return }   // 기다리지 않는 결과는 무시
        waiting = false
        if holding { holding = false; talk?.setRecording(false) }
        let text = Bridge.get(Bridge.Key.final)
        let err = Bridge.get(Bridge.Key.error)
        setTalk(text.isEmpty ? (err.isEmpty ? L("인식 없음", "Nothing heard") : err) : L("입력됨", "Inserted"), revert: true)
        if !text.isEmpty { composer.reset(); hostInsertNow(text + " ") }   // 다음 받아쓰기와 띄어지도록 끝에 공백
    }
}
