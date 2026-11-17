import UIKit

private final class Key: UIButton {
    static var haptic = UIImpactFeedbackGenerator(style: .light)
    static var lastFire = Date.distantPast
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.55 : 1 } }

    // 키를 누르는 순간 햅틱 (전체 접근 허용이 켜져 있어야 울린다)
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        // 터치 순간 바로 울린다. 한동안 안 눌렀으면 생성기를 새로 만들어 끊긴 연결을 복구한다.
        if Date().timeIntervalSince(Key.lastFire) > 5 { Key.haptic = UIImpactFeedbackGenerator(style: .light) }
        Key.lastFire = Date()
        Key.haptic.impactOccurred()
        Key.haptic.prepare()
        return super.beginTracking(touch, with: event)
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

    private var row2: UIStackView?
    private let talkTitle = L(" 누르고 말하기", " Hold to talk")
    private let keyArea = UIStackView()
    private var talk = Key(type: .custom)
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

        keyArea.axis = .vertical
        keyArea.spacing = 11.3
        keyArea.distribution = .fillEqually

        let root = UIStackView(arrangedSubviews: [keyArea])
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6.5),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6.5),
        ])
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
        Key.haptic.prepare()
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
        Key.haptic = UIImpactFeedbackGenerator(style: .light); Key.haptic.prepare()
        if !hasFullAccess { setTalk(L(" 전체 접근을 켜 주세요", " Turn on Full Access"), revert: true) }   // 햅틱·받아쓰기에 필요
    }

    // SnapVoice 고유 디자인: 보라·파랑 강조색, 둥근 키, 둥근 글꼴 (기본 키보드와 구별)
    private static let accent = UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 1)
    private static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : .white }
    private static let fnColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 0.38) : UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 0.20) }

    private func makeKey(_ title: String, fn: Bool = false, size: CGFloat = 22) -> Key {
        let b = Key(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        b.titleLabel?.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.6
        b.backgroundColor = fn ? Self.fnColor : Self.keyColor
        b.layer.cornerRadius = 12
        b.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        b.setContentHuggingPriority(.defaultLow, for: .vertical)
        return b
    }

    private func symbol(_ name: String, fn: Bool = true) -> Key {
        let b = makeKey("", fn: fn)
        b.setImage(UIImage(systemName: name), for: .normal)
        b.tintColor = .label
        b.accessibilityLabel = [
            "delete.left": L("삭제", "Delete"), "return": L("줄바꿈", "Return"), "globe": L("다음 키보드", "Next keyboard"),
            "shift": L("쉬프트", "Shift"), "shift.fill": L("쉬프트 켜짐", "Shift on"), "capslock.fill": L("쉬프트 고정", "Caps Lock"),
        ][name]
        return b
    }

    private func row(_ views: [UIView], inset: CGFloat = 0, spacing: CGFloat = 6) -> UIStackView {
        let s = UIStackView(arrangedSubviews: views)
        s.spacing = spacing; s.distribution = .fillEqually
        if inset > 0 { s.isLayoutMarginsRelativeArrangement = true; s.layoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset) }
        return s
    }

    private func rebuild() {
        keyArea.arrangedSubviews.forEach { keyArea.removeArrangedSubview($0); $0.removeFromSuperview() }
        let rows: [String]
        switch layer {
        case .korean: rows = shift > 0 ? koShift : koRows
        case .english: rows = shift > 0 ? enRows.map { $0.uppercased() } : enRows
        case .number: rows = numRows
        case .symbol: rows = symRows
        }
        func letters(_ s: String) -> [UIView] {
            s.map { ch in
                let k = makeKey(String(ch))
                k.addAction(UIAction { [weak self] _ in self?.typeLetter(String(ch)) }, for: .touchDown)
                return k
            }
        }
        keyArea.addArrangedSubview(row(letters(rows[0])))
        let r2 = row(letters(rows[1]))
        r2.isLayoutMarginsRelativeArrangement = true
        row2 = (rows[1].count < 10 && layer != .number && layer != .symbol) ? r2 : nil
        keyArea.addArrangedSubview(r2)

        // 3행: [모드키] 글자들 [삭제]
        let left: Key
        if layer == .number || layer == .symbol {
            left = makeKey(layer == .number ? "#+=" : "123", fn: true, size: 15)
            left.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.layer = self.layer == .number ? .symbol : .number; self.rebuild()
            }, for: .touchUpInside)
        } else {
            left = symbol(shift == 2 ? "capslock.fill" : (shift == 1 ? "shift.fill" : "shift"))
            left.addAction(UIAction { [weak self] _ in self?.tapShift() }, for: .touchUpInside)
        }
        let del = symbol("delete.left")
        del.addAction(UIAction { [weak self] _ in self?.startDelete() }, for: .touchDown)
        del.addAction(UIAction { [weak self] _ in self?.stopDelete() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let mid = row(letters(rows[2]))
        let r3 = UIStackView(arrangedSubviews: [left, mid, del])
        r3.spacing = 14
        left.widthAnchor.constraint(equalToConstant: 45).isActive = true
        del.widthAnchor.constraint(equalToConstant: 45).isActive = true
        keyArea.addArrangedSubview(r3)

        // 4행: [123] [한/A] [지구본] [누르고 말하기] [space] [return]
        let isLetters = layer == .korean || layer == .english
        let modeKey = makeKey(isLetters ? "123" : (lastLetter == .korean ? "가" : "ABC"), fn: true, size: 18)
        modeKey.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.composer.reset()
            self.layer = (self.layer == .korean || self.layer == .english) ? .number : self.lastLetter
            self.rebuild()
        }, for: .touchUpInside)
        talk = makeKey(talkTitle, size: 13)
        talk.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)), for: .normal)
        talk.accessibilityLabel = L("누르고 말하기", "Hold to talk")
        talk.accessibilityHint = L("누르고 있는 동안 말하면 글자로 입력됩니다", "Speak while holding to insert text")
        talk.tintColor = .white
        talk.setTitleColor(.white, for: .normal)
        talk.backgroundColor = Self.accent
        talk.titleLabel?.numberOfLines = 2
        talk.titleLabel?.textAlignment = .center
        talk.titleLabel?.lineBreakMode = .byTruncatingHead
        talk.addTarget(self, action: #selector(talkDown), for: .touchDown)
        talk.addTarget(self, action: #selector(talkUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        // 한/영 전환 전용 키: 현재 언어를 "한" 또는 "A"로 표시하고, 누르면 바뀐다.
        let lang = makeKey(lastLetter == .korean ? "한" : "A", fn: true, size: 18)
        lang.accessibilityLabel = L("한영 전환", "Switch language")
        lang.accessibilityValue = lastLetter == .korean ? L("한글", "Korean") : L("영어", "English")
        lang.addAction(UIAction { [weak self] _ in self?.toggleLanguage() }, for: .touchUpInside)
        let space = makeKey("space", size: 15)
        space.accessibilityLabel = L("스페이스", "Space")
        space.setTitleColor(.secondaryLabel, for: .normal)
        space.addAction(UIAction { [weak self] _ in self?.composer.reset(); self?.textDocumentProxy.insertText(" ") }, for: .touchUpInside)
        let ret = symbol("return")
        ret.backgroundColor = Self.accent
        ret.tintColor = .white
        ret.addAction(UIAction { [weak self] _ in self?.composer.reset(); self?.textDocumentProxy.insertText("\n") }, for: .touchUpInside)

        var left4: [UIView] = [modeKey]
        if needsInputModeSwitchKey {   // 홈 버튼 기기에서만 자체 지구본 표시
            let globe = symbol("globe")
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            left4.append(globe)
        }
        let r4 = UIStackView(arrangedSubviews: left4 + [lang, talk, space, ret])
        r4.spacing = 6; r4.distribution = .fill
        modeKey.widthAnchor.constraint(equalToConstant: 56).isActive = true
        lang.widthAnchor.constraint(equalToConstant: 44).isActive = true
        left4.dropFirst().forEach { $0.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        ret.widthAnchor.constraint(equalToConstant: 56).isActive = true
        talk.widthAnchor.constraint(equalTo: space.widthAnchor).isActive = true
        keyArea.addArrangedSubview(r4)
    }

    private func setTalkIcon(_ name: String) {
        talk.setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)), for: .normal)
    }

    private func setTalk(_ t: String, revert: Bool = false, icon: String? = nil) {
        talk.setTitle(t, for: .normal)
        if let icon { setTalkIcon(icon) }
        if revert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.holding else { return }
                self.talk.setTitle(self.talkTitle, for: .normal)
                self.setTalkIcon("mic.fill")
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width - 13
        let key = (w - 9 * 6) / 10
        let inset = (key + 6) / 2
        row2?.layoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
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
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in self?.deleteOnce() }
        }
    }
    private func stopDelete() { repeatTimer?.invalidate(); repeatTimer = nil }

    // MARK: 음성
    private func toggleLanguage() {
        composer.reset()
        lastLetter = lastLetter == .korean ? .english : .korean
        layer = lastLetter; shift = 0
        Bridge.set(lastLetter == .korean ? "ko" : "en", Bridge.Key.lang)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        rebuild()
    }

    @objc private func talkDown() {
        guard hasFullAccess else { setTalk(L("전체 접근 허용 필요", "Allow Full Access"), revert: true); return }
        guard Bridge.isSessionAlive else {
            setTalk(L(" 세션 꺼짐", " Session off"), revert: true, icon: "mic.slash.fill")   // 키보드는 다른 앱을 열지 않는다(4.4.1)
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
        talk.backgroundColor = .systemRed
        Bridge.post(.start)
    }

    @objc private func talkUp() {
        guard holding else { return }
        holding = false; waiting = true
        setTalk(L("변환 중…", "Transcribing…"))
        let id = pressID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pressID == id, !self.holding, self.waiting else { return }
            self.waiting = false
            self.setTalk(L("앱 응답 없음", "No response"), revert: true)
        }
        talk.backgroundColor = Self.accent
        Bridge.post(.stop)
    }

    private func finishDictation() {
        guard waiting || holding else { return }   // 기다리지 않는 결과는 무시
        waiting = false
        if holding { holding = false; talk.backgroundColor = Self.accent }
        let text = Bridge.get(Bridge.Key.final)
        let err = Bridge.get(Bridge.Key.error)
        setTalk(text.isEmpty ? (err.isEmpty ? L("인식 없음", "Nothing heard") : err) : L("입력됨", "Inserted"), revert: true)
        if !text.isEmpty { composer.reset(); textDocumentProxy.insertText(text + " ") }   // 다음 받아쓰기와 띄어지도록 끝에 공백
    }
}
