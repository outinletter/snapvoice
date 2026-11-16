import UIKit

private final class Key: UIButton {
    override var isHighlighted: Bool { didSet { alpha = isHighlighted ? 0.55 : 1 } }
}

final class KeyboardViewController: UIInputViewController {
    private enum Layer { case korean, english, number, symbol }

    private var layer: Layer = .korean
    private var lastLetter: Layer = .korean
    private var shift = 0                 // 0 꺼짐, 1 한 번, 2 고정
    private var lastShiftTap = Date.distantPast
    private var composer = HangulComposer()

    private var row2: UIStackView?
    private let talkTitle = "🎙 누르고 말하기"
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
            self.setTalk(t.isEmpty ? "듣는 중…" : t)
        }
        Bridge.observe(.result) { [weak self] in self?.finishDictation() }
    }

    private var heightC: NSLayoutConstraint?
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if heightC == nil {
            let c = view.heightAnchor.constraint(equalToConstant: 209)
            c.priority = .init(999); c.isActive = true; heightC = c
        }
    }

    private func makeKey(_ title: String, fn: Bool = false, size: CGFloat = 22) -> Key {
        let b = Key(type: .custom)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.label, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: size)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.titleLabel?.minimumScaleFactor = 0.6
        b.backgroundColor = fn
            ? UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }
            : UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : .white }
        b.layer.cornerRadius = 8
        b.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        b.setContentHuggingPriority(.defaultLow, for: .vertical)
        return b
    }

    private func symbol(_ name: String, fn: Bool = true) -> Key {
        let b = makeKey("", fn: fn)
        b.setImage(UIImage(systemName: name), for: .normal)
        b.tintColor = .label
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
        talk.titleLabel?.numberOfLines = 2
        talk.titleLabel?.textAlignment = .center
        talk.titleLabel?.lineBreakMode = .byTruncatingHead
        talk.addTarget(self, action: #selector(talkDown), for: .touchDown)
        talk.addTarget(self, action: #selector(talkUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let space = makeKey(lastLetter == .korean ? "" : "space", size: 15)
        let tag = UILabel(); tag.text = lastLetter == .korean ? "한" : "A"
        tag.font = .systemFont(ofSize: 15); tag.textColor = .secondaryLabel
        tag.translatesAutoresizingMaskIntoConstraints = false
        space.addSubview(tag)
        tag.trailingAnchor.constraint(equalTo: space.trailingAnchor, constant: -10).isActive = true
        tag.bottomAnchor.constraint(equalTo: space.bottomAnchor, constant: -6).isActive = true
        space.addAction(UIAction { [weak self] _ in self?.composer.reset(); self?.textDocumentProxy.insertText(" ") }, for: .touchUpInside)
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(toggleLanguage(_:)))
        lp.minimumPressDuration = 0.4
        space.addGestureRecognizer(lp)
        let ret = symbol("return")
        ret.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.5, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }
        ret.addAction(UIAction { [weak self] _ in self?.composer.reset(); self?.textDocumentProxy.insertText("\n") }, for: .touchUpInside)

        var left4: [UIView] = [modeKey]
        if needsInputModeSwitchKey {   // 홈 버튼 기기에서만 자체 지구본 표시
            let globe = symbol("globe")
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            left4.append(globe)
        }
        let r4 = UIStackView(arrangedSubviews: left4 + [talk, space, ret])
        r4.spacing = 6; r4.distribution = .fill
        modeKey.widthAnchor.constraint(equalToConstant: 64).isActive = true
        left4.dropFirst().forEach { $0.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        ret.widthAnchor.constraint(equalToConstant: 64).isActive = true
        talk.widthAnchor.constraint(equalTo: space.widthAnchor).isActive = true
        keyArea.addArrangedSubview(r4)
    }

    private func setTalk(_ t: String, revert: Bool = false) {
        talk.setTitle(t, for: .normal)
        if revert {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.holding else { return }
                self.talk.setTitle(self.talkTitle, for: .normal)
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
    private func syncComposer() {
        guard composer.isComposing, let before = textDocumentProxy.documentContextBeforeInput else { return }
        if before.last.map({ String($0) }) != composer.text { composer.reset() }
    }

    private func apply(_ e: HangulComposer.Edit) {
        if e.delete { textDocumentProxy.deleteBackward() }
        if !e.insert.isEmpty { textDocumentProxy.insertText(e.insert) }
    }

    private func typeLetter(_ s: String) {
        if layer == .korean, let ch = s.first {
            syncComposer(); apply(composer.input(ch))
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
    @objc private func toggleLanguage(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        composer.reset()
        lastLetter = lastLetter == .korean ? .english : .korean
        layer = lastLetter; shift = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        rebuild()
    }

    @objc private func talkDown() {
        guard hasFullAccess else { setTalk("전체 접근 허용 필요", revert: true); return }
        guard Bridge.isSessionAlive else {
            setTalk("앱에서 세션을 켜세요", revert: true)
            openApp(); return
        }
        holding = true; acked = false; pressID += 1
        Bridge.set(String(Date().timeIntervalSince1970), Bridge.Key.startAt)
        Bridge.set(lastLetter == .korean ? "ko-KR" : "en-US", Bridge.Key.locale)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.holding, !self.acked else { return }
            self.setTalk("앱 응답 없음")
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        setTalk("연결 중…")
        talk.backgroundColor = .systemRed
        Bridge.post(.start)
    }

    @objc private func talkUp() {
        guard holding else { return }
        holding = false; waiting = true
        setTalk("변환 중…")
        let id = pressID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pressID == id, !self.holding, self.waiting else { return }
            self.waiting = false
            self.setTalk("앱 응답 없음", revert: true)
        }
        talk.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : .white }
        Bridge.post(.stop)
    }

    private func finishDictation() {
        guard waiting || holding else { return }   // 기다리지 않는 결과는 무시
        waiting = false
        if holding { holding = false; talk.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : .white } }
        let text = Bridge.get(Bridge.Key.final)
        let err = Bridge.get(Bridge.Key.error)
        setTalk(text.isEmpty ? (err.isEmpty ? "인식 없음" : err) : "입력됨", revert: true)
        if !text.isEmpty { composer.reset(); textDocumentProxy.insertText(text + " ") }   // 다음 받아쓰기와 띄어지도록 끝에 공백
    }

    private func openApp() {
        guard let url = URL(string: "snapvoice://start") else { return }
        var r: UIResponder? = self
        while let cur = r {
            if let app = cur as? UIApplication { app.open(url, options: [:], completionHandler: nil); return }
            r = cur.next
        }
    }
}
