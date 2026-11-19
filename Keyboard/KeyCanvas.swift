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
    var label: String?           // VoiceOver
    var value: String?
    var hint: String?
}

/// 모든 키를 한 뷰의 레이어로 그리고, 터치를 한 곳에서 받아 가장 가까운 키로 보낸다.
/// 버튼 뷰 수십 개를 두는 방식보다 키를 누를 때 하는 일이 훨씬 적다.
final class KeyCanvas: UIView {
    static let accent = UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 1)
    private static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : .white }
    private static let fnColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 0.38) : UIColor(red: 0.36, green: 0.33, blue: 0.95, alpha: 0.20) }

    private static let reach: CGFloat = 30   // 키에서 이만큼 떨어진 곳까지 가장 가까운 키로 인식
    private let margin: CGFloat = 6.5, top: CGFloat = 5, vGap: CGFloat = 6   // 줄 간격을 줄여 키를 키보드 높이 안에서 더 높게

    var onDown: ((KeyID) -> Void)?
    var onUp: ((KeyID, Bool) -> Void)?
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
        switch it.spec.style { case .normal: return Self.keyColor; case .fn: return Self.fnColor; case .accent: return Self.accent }
    }
    private func textColor(_ it: Item) -> UIColor {
        it.spec.titleColor ?? (it.spec.style == .accent ? .white : .label)
    }
    private func font(_ size: CGFloat) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    }
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
        refreshAll(); items.forEach { layoutContent($0) }
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

    // MARK: 터치
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
        for it in items where it.spec.id == id { it.layer.opacity = on ? 0.55 : 1 }
        CATransaction.commit()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            guard let it = key(at: t.location(in: self)) else { continue }
            let id = it.spec.id
            active[t] = id
            Haptics.shared.tap()
            press(id, true)
            onDown?(id)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            guard let id = active.removeValue(forKey: t) else { continue }
            press(id, false)
            let inside = !cancelled && key(at: t.location(in: self))?.spec.id == id
            onUp?(id, inside)
        }
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

    fileprivate func activate(_ id: KeyID) { onDown?(id); onUp?(id, true) }
}

private final class AXKey: UIAccessibilityElement {
    weak var canvas: KeyCanvas?
    var keyID: KeyID = .space
    override func accessibilityActivate() -> Bool { canvas?.activate(keyID); return true }
}
