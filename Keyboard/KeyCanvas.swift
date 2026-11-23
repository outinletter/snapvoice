import UIKit

enum KeyID: Equatable {
    case letter(String), shift, delete, mode, symbols, lang, globe, talk, space, ret
}
enum KeyStyle { case normal, fn, accent }

struct KeySpec {
    var id: KeyID
    var title = ""
    var symbol: String?
    var style: KeyStyle = .normal
    var fontSize: CGFloat = 22
    var width: CGFloat?          // nil이면 남는 폭을 나눠 가짐
    var gapAfter: CGFloat = 6
    var titleColor: UIColor?
    var fill: UIColor?           // 지정하면 기본 배경색 대신 사용 (예: 켜진 쉬프트)
    var label: String?           // VoiceOver
    var value: String?
    var hint: String?
}

/// 모든 키를 한 뷰의 레이어로 그리고, 터치를 한 곳에서 받아 가장 가까운 키로 보낸다.
/// 버튼 뷰 수십 개를 두는 방식보다 키를 누를 때 하는 일이 훨씬 적다.
final class KeyCanvas: UIView {
    static let accent = UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 1)
    // 아이폰 기본 키보드와 같은 색: 다크에서는 모든 키가 같은 회색, 라이트에서는 글자 키 흰색·기능 키 회색
    private static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : .white }
    private static let fnColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1) }

    private static let reach: CGFloat = 30   // 키에서 이만큼 떨어진 곳까지 가장 가까운 키로 인식
    private let margin: CGFloat = 6.5, top: CGFloat = 5, vGap: CGFloat = 6   // 줄 간격을 줄여 키를 키보드 높이 안에서 더 높게

    var onDown: ((KeyID) -> Void)?
    var onUp: ((KeyID, Bool) -> Void)?
    var onCommit: ((KeyID) -> Void)?
    var onGlobe: ((UIButton) -> Void)?
    var insetRows: [Bool] = []
    var rows: [[KeySpec]] = [] { didSet { rebuildLayers() } }
    private(set) var globeButton: UIButton?

    private final class Item {
        var spec: KeySpec
        var title: String
        var symbol: String?
        var fill: UIColor?
        var frame = CGRect.zero
        let layer = CALayer()
        var text: CATextLayer?
        var icon: CALayer?
        init(_ s: KeySpec) { spec = s; title = s.title; symbol = s.symbol }
    }
    private var items: [Item] = []
    private var active: [UITouch: KeyID] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 구성
    private func rebuildLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        items.forEach { $0.layer.removeFromSuperlayer() }
        items = rows.flatMap { $0 }.map { Item($0) }
        for it in items {
            it.layer.cornerRadius = 8
            it.layer.shadowColor = UIColor.black.cgColor
            it.layer.shadowOffset = CGSize(width: 0, height: 1)
            it.layer.shadowRadius = 0
            it.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0 : 0.3
            layer.addSublayer(it.layer)
            if !it.title.isEmpty { addText(it) }
            if it.symbol != nil { addIcon(it) }
        }
        globeButton?.removeFromSuperview(); globeButton = nil
        if items.contains(where: { $0.spec.id == .globe }) {
            let b = UIButton(type: .custom)
            b.isMultipleTouchEnabled = true
            addSubview(b); globeButton = b
            onGlobe?(b)
        }
        refreshAll()
        layoutKeys()
        CATransaction.commit()
        accessibilityElements = nil
    }

    private func addText(_ it: Item) {
        let t = CATextLayer()
        t.contentsScale = traitCollection.displayScale
        t.alignmentMode = .center
        t.truncationMode = .start
        t.isWrapped = true
        it.layer.addSublayer(t); it.text = t
    }

    private func addIcon(_ it: Item) {
        let i = CALayer()
        i.contentsScale = traitCollection.displayScale
        it.layer.addSublayer(i); it.icon = i
    }

    /// 제목·아이콘·색을 갱신한다 (레이어는 새로 만들지 않는다)
    func update(_ id: KeyID, title: String? = nil, symbol: String?? = nil, fill: UIColor?? = nil) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for it in items where it.spec.id == id {
            if let title { it.title = title; if it.text == nil && !title.isEmpty { addText(it) } }
            if let symbol { it.symbol = symbol; if it.icon == nil && symbol != nil { addIcon(it) } }
            if let fill { it.fill = fill }
            refresh(it); layoutContent(it)
        }
        CATransaction.commit()
    }

    private func baseFill(_ it: Item) -> UIColor {
        if let f = it.spec.fill { return f }
        switch it.spec.style { case .normal: return Self.keyColor; case .fn: return Self.fnColor; case .accent: return Self.accent }
    }
    private func textColor(_ it: Item) -> UIColor {
        it.spec.titleColor ?? (it.spec.style == .accent ? .white : .label)
    }
    private func font(_ size: CGFloat) -> UIFont { .systemFont(ofSize: size, weight: .regular) }
    private func attributed(_ it: Item) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingHead
        return NSAttributedString(string: it.title, attributes: [
            .font: font(it.spec.fontSize), .paragraphStyle: p,
            .foregroundColor: textColor(it).resolvedColor(with: traitCollection)])
    }

    private func refresh(_ it: Item) {
        it.layer.backgroundColor = (it.fill ?? baseFill(it)).resolvedColor(with: traitCollection).cgColor
        it.text?.string = attributed(it)
        it.text?.isHidden = it.title.isEmpty
        if let name = it.symbol, let icon = it.icon {
            let cfg = UIImage.SymbolConfiguration(pointSize: it.spec.title.isEmpty ? 19 : 14, weight: .medium)
            if let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(textColor(it).resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal) {
                let r = UIGraphicsImageRenderer(size: img.size)
                let drawn = r.image { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
                icon.contents = drawn.cgImage
                icon.bounds = CGRect(origin: .zero, size: img.size)
            }
            icon.isHidden = false
        } else { it.icon?.isHidden = true }
    }

    private func refreshAll() { items.forEach { refresh($0) } }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        refreshAll(); items.forEach { layoutContent($0); $0.layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0 : 0.3 }
        CATransaction.commit()
    }

    // MARK: 배치
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layoutKeys()
        CATransaction.commit()
    }

    private func layoutKeys() {
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0, !rows.isEmpty else { return }
        let rowH = (H - top - CGFloat(rows.count - 1) * vGap) / CGFloat(rows.count)
        let k10 = (W - margin * 2 - 6 * 9) / 10
        var idx = 0
        for (r, row) in rows.enumerated() {
            let inset = (r < insetRows.count && insetRows[r]) ? (k10 + 6) / 2 : 0
            let x0 = margin + inset, x1 = W - margin - inset
            let fixed = row.reduce(CGFloat(0)) { $0 + ($1.width ?? 0) }
            let gaps = row.dropLast().reduce(CGFloat(0)) { $0 + $1.gapAfter }
            let flex = row.filter { $0.width == nil }.count
            let flexW = flex > 0 ? (x1 - x0 - fixed - gaps) / CGFloat(flex) : 0
            let y = top + CGFloat(r) * (rowH + vGap)
            var x = x0
            for spec in row {
                let w = spec.width ?? flexW
                let it = items[idx]; idx += 1
                it.frame = CGRect(x: x, y: y, width: w, height: rowH)
                it.layer.frame = it.frame
                it.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: it.frame.size), cornerRadius: 8).cgPath
                layoutContent(it)
                if it.spec.id == .globe { globeButton?.frame = it.frame }
                x += w + spec.gapAfter
            }
        }
    }

    private func layoutContent(_ it: Item) {
        let b = CGRect(origin: .zero, size: it.frame.size)
        guard b.width > 0 else { return }
        var iconW: CGFloat = 0, iconH: CGFloat = 0
        if let icon = it.icon, !icon.isHidden { iconW = icon.bounds.width; iconH = icon.bounds.height }
        let hasText = it.text != nil && !it.title.isEmpty
        var tw: CGFloat = 0, th: CGFloat = 0
        if hasText {
            let f = font(it.spec.fontSize)
            let maxW = max(10, b.width - iconW - (iconW > 0 ? 2 : 0) - 12)
            let r = attributed(it).boundingRect(with: CGSize(width: maxW, height: f.lineHeight * 2 + 2), options: [.usesLineFragmentOrigin], context: nil)
            tw = min(ceil(r.width) + 2, maxW); th = min(ceil(r.height), f.lineHeight * 2)
        }
        let gap: CGFloat = (iconW > 0 && tw > 0) ? 2 : 0   // 아이콘과 글자 사이를 바짝 붙인다
        let x0 = (b.width - iconW - gap - tw) / 2
        if let icon = it.icon, iconW > 0 { icon.frame = CGRect(x: x0, y: (b.height - iconH) / 2, width: iconW, height: iconH) }
        if hasText, let t = it.text { t.frame = CGRect(x: x0 + iconW + gap, y: (b.height - th) / 2, width: tw, height: th) }
    }

    // MARK: 터치 (아이폰 기본 키보드와 같게: 손가락을 뗄 때 입력, 누른 채 미끄러지면 손가락 아래 키가 입력)
    private var popups: [UITouch: CALayer] = [:]

    /// 누르는 동안 계속 동작하는 키(삭제 반복, 누르고 말하기). 나머지는 뗄 때 입력한다.
    private static func holdKey(_ id: KeyID) -> Bool { id == .delete || id == .talk }

    private func key(at p: CGPoint) -> Item? {
        var best: (Item, CGFloat)?
        for it in items where it.spec.id != .globe {
            let f = it.frame
            if f.contains(p) { return it }
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            let d = hypot(dx, dy)
            if d <= Self.reach, best == nil || d < best!.1 { best = (it, d) }
        }
        return best?.0
    }

    private func press(_ id: KeyID, _ on: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for it in items where it.spec.id == id { it.layer.opacity = on ? 0.6 : 1 }
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let it = key(at: t.location(in: self)) else { continue }
            let id = it.spec.id
            active[t] = id
            Haptics.shared.tap()          // 진동은 닿는 순간 (기본 키보드와 같음)
            press(id, true)
            showPopup(t, it)
            if Self.holdKey(id) { onDown?(id) }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let cur = active[t], !Self.holdKey(cur),
                  let it = key(at: t.location(in: self)), it.spec.id != cur, !Self.holdKey(it.spec.id) else { continue }
            press(cur, false)
            active[t] = it.spec.id
            press(it.spec.id, true)
            showPopup(t, it)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            guard let id = active.removeValue(forKey: t) else { continue }
            press(id, false)
            hidePopup(t)
            if Self.holdKey(id) {
                onUp?(id, !cancelled && key(at: t.location(in: self))?.spec.id == id)
            } else if !cancelled {
                onCommit?(id)
            }
        }
    }

    // MARK: 키 미리보기 (눌린 글자 키 위에 크게)
    private func showPopup(_ t: UITouch, _ it: Item) {
        hidePopup(t)
        guard case .letter(let s) = it.spec.id, !s.isEmpty else { return }
        let f = it.frame
        let w = f.width * 1.5, h = f.height * 1.2
        var x = f.midX - w / 2
        x = max(2, min(bounds.width - w - 2, x))
        var y = f.minY - h - 6
        if y < 2 { y = max(2, f.midY - h / 2) }          // 맨 윗줄은 위 공간이 없어 키 위에 겹쳐 그린다
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let bubble = CALayer()
        bubble.frame = CGRect(x: x, y: y, width: w, height: h)
        bubble.cornerRadius = 10
        bubble.backgroundColor = Self.keyColor.resolvedColor(with: traitCollection).cgColor
        bubble.shadowColor = UIColor.black.cgColor
        bubble.shadowOffset = CGSize(width: 0, height: 2)
        bubble.shadowRadius = 4
        bubble.shadowOpacity = 0.3
        bubble.zPosition = 100
        let text = CATextLayer()
        text.contentsScale = traitCollection.displayScale
        text.alignmentMode = .center
        let f34 = UIFont.systemFont(ofSize: 34, weight: .regular)
        text.string = NSAttributedString(string: s, attributes: [
            .font: f34, .foregroundColor: UIColor.label.resolvedColor(with: traitCollection)])
        text.frame = CGRect(x: 0, y: (h - f34.lineHeight) / 2, width: w, height: ceil(f34.lineHeight))
        bubble.addSublayer(text)
        layer.addSublayer(bubble)
        popups[t] = bubble
        CATransaction.commit()
    }

    private func hidePopup(_ t: UITouch) {
        guard let b = popups.removeValue(forKey: t) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        b.removeFromSuperlayer()
        CATransaction.commit()
    }

    // MARK: VoiceOver
    override var isAccessibilityElement: Bool { get { false } set {} }
    override var accessibilityElements: [Any]? {
        get {
            items.map { it in
                let e = AXKey(accessibilityContainer: self)
                e.canvas = self; e.keyID = it.spec.id
                e.accessibilityLabel = it.spec.label ?? it.title
                e.accessibilityValue = it.spec.value
                e.accessibilityHint = it.spec.hint
                e.accessibilityTraits = .button
                e.accessibilityFrameInContainerSpace = it.frame
                return e
            }
        }
        set {}
    }

    fileprivate func activate(_ id: KeyID) {
        if Self.holdKey(id) { onDown?(id); onUp?(id, true) } else { onCommit?(id) }
    }
}

private final class AXKey: UIAccessibilityElement {
    weak var canvas: KeyCanvas?
    var keyID: KeyID = .space
    override func accessibilityActivate() -> Bool { canvas?.activate(keyID); return true }
}
