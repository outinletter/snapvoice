import UIKit

/// NativeTone 키보드의 키 디자인과 같은 색
enum KeyboardTheme {
    static let background = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1) }
    static let letterKey = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.42, alpha: 1) : .white }
    static let specialKey = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1) }
    static let voice = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.62, green: 0.56, blue: 0.88, alpha: 1) : UIColor(red: 0.76, green: 0.70, blue: 0.96, alpha: 1) }   // 누르고 말하기 키(파스텔 보라)
    static let voiceText = UIColor(red: 0.16, green: 0.11, blue: 0.38, alpha: 1)   // 파스텔 배경 위 진한 보라 글자
}

/// 키 하나. 눌렀을 때 진동·미리보기, 손가락을 뗄 때 입력(onTap). 삭제는 누르는 동안 반복(onRepeat).
final class KeyButton: UIButton {
    enum Style { case letter, special, voice }

    var onTap: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onDown: (() -> Void)?      // 누르는 순간 (누르고 말하기)
    var onUp: (() -> Void)?        // 뗄 때·취소될 때 (누르고 말하기)
    var popupAbove = true          // 맨 윗줄은 위 공간이 없어 키 위에 겹쳐 그린다

    private let style: Style
    /// 키 미리보기 풍선은 하나를 만들어 두고 계속 재사용한다 (누를 때마다 뷰를 만들지 않는다)
    static weak var popupHost: UIView?
    private static let sharedPopup: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 34)
        l.textColor = .label
        l.textAlignment = .center
        l.backgroundColor = KeyboardTheme.letterKey
        l.layer.cornerRadius = 8
        l.layer.masksToBounds = true
        l.isHidden = true
        return l
    }()
    private var delayTimer: Timer?
    private var repeatTimer: Timer?

    init(title: String? = nil, symbol: String? = nil, style: Style = .letter, fontSize: CGFloat = 22) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = Self.fill(style)
        layer.cornerRadius = 5
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 0.3
        setTitleColor(style == .voice ? KeyboardTheme.voiceText : .label, for: .normal)
        titleLabel?.font = .systemFont(ofSize: fontSize)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.6
        tintColor = style == .voice ? KeyboardTheme.voiceText : .label
        if let title { setTitle(title, for: .normal) }
        if let symbol { setSymbol(symbol, size: style == .voice ? 13 : 17) }

        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.onRepeat == nil && self.onDown == nil { self.onTap?() }
        }, for: .touchUpInside)

        addAction(UIAction { [weak self] _ in
            Metrics.shared.time("touchDown") {
                Haptics.shared.tap()
                self?.showPopup()
                self?.beginRepeat()
                self?.onDown?()
            }
        }, for: .touchDown)
        for e: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
            addAction(UIAction { [weak self] _ in self?.endRepeat(); self?.hidePopup(); self?.onUp?() }, for: e)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private static func fill(_ s: Style) -> UIColor {
        switch s { case .letter: return KeyboardTheme.letterKey; case .special: return KeyboardTheme.specialKey; case .voice: return KeyboardTheme.voice }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    func setSymbol(_ name: String, size: CGFloat = 17) {
        setImage(UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)), for: .normal)
    }

    /// 쉬프트처럼 켜짐 표시가 필요한 키
    func setActive(_ active: Bool) {
        backgroundColor = active ? KeyboardTheme.letterKey : KeyboardTheme.specialKey
    }

    /// 누르는 동안 빨갛게 (누르고 말하기)
    func setRecording(_ on: Bool) {
        backgroundColor = on ? .systemRed : Self.fill(style)
        let c: UIColor = on ? .white : KeyboardTheme.voiceText   // 빨간 배경에서는 흰 글자
        setTitleColor(c, for: .normal)
        tintColor = c
    }

    /// 아이폰 기본 키보드처럼 눌린 글자를 위에 크게 보여 준다.
    private func showPopup() {
        guard style == .letter, let t = title(for: .normal), t.count == 1, let host = Self.popupHost else { return }
        let l = Self.sharedPopup
        let f = convert(bounds, to: host)
        let w = f.width * 1.5, h = f.height * 1.15
        let x = max(2, min(host.bounds.width - w - 2, f.midX - w / 2))
        let y = popupAbove ? f.minY - h - 4 : f.minY - (h - f.height) / 2
        l.text = t
        l.frame = CGRect(x: x, y: y, width: w, height: h)
        if l.superview !== host { host.addSubview(l) } else if host.subviews.last !== l { host.bringSubviewToFront(l) }
        l.isHidden = false
    }

    private func hidePopup() { Self.sharedPopup.isHidden = true }

    private func beginRepeat() {
        guard let onRepeat else { return }
        onRepeat()
        delayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in onRepeat() }
        }
    }

    private func endRepeat() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
    }
}
