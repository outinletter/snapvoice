import Foundation

/// 두벌식 한글 조합기. 입력마다 "직전 글자를 지우고 다시 쓸지(delete)"와 "쓸 문자열(insert)"을 돌려준다.
struct HangulComposer {
    struct Edit { var delete: Bool; var insert: String }

    static let cho = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let jung = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    static let jong: [Character] = [" "] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    static let vowels = Set("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅛㅜㅠㅡㅣ")
    static let vowelCombo: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"]
    static let jongCombo: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"]

    private var c: Character?   // 초성
    private var v: Character?   // 중성
    private var f: Character?   // 종성

    var isComposing: Bool { c != nil || v != nil }
    mutating func reset() { c = nil; v = nil; f = nil }

    var text: String {
        guard let c else { return v.map { String($0) } ?? "" }
        guard let v else { return String(c) }
        let ci = Self.cho.firstIndex(of: c) ?? 0
        let vi = Self.jung.firstIndex(of: v) ?? 0
        let fi = f.flatMap { Self.jong.firstIndex(of: $0) } ?? 0
        return String(UnicodeScalar(UInt32(0xAC00 + (ci * 21 + vi) * 28 + fi))!)
    }

    private static func split(_ x: Character, _ table: [String: Character]) -> (Character, Character)? {
        for (k, val) in table where val == x { let a = Array(k); return (a[0], a[1]) }
        return nil
    }

    mutating func input(_ ch: Character) -> Edit {
        if Self.vowels.contains(ch) {
            guard let cc = c else {            // 초성 없음: 낱자 모음
                reset(); v = ch; return Edit(delete: false, insert: String(ch))
            }
            _ = cc
            guard let vv = v else { v = ch; return Edit(delete: true, insert: text) }
            guard let ff = f else {
                if let m = Self.vowelCombo[String([vv, ch])] { v = m; return Edit(delete: true, insert: text) }
                reset(); v = ch; return Edit(delete: false, insert: String(ch))
            }
            let keep: Character?, move: Character
            if let (a, b) = Self.split(ff, Self.jongCombo) { keep = a; move = b } else { keep = nil; move = ff }
            f = keep
            let first = text
            c = move; v = ch; f = nil
            return Edit(delete: true, insert: first + text)
        }
        // 자음
        guard c != nil, let vv = v else {
            reset(); c = ch; return Edit(delete: false, insert: String(ch))
        }
        _ = vv
        guard let ff = f else {
            if Self.jong.contains(ch) { f = ch; return Edit(delete: true, insert: text) }
            reset(); c = ch; return Edit(delete: false, insert: String(ch))
        }
        if let m = Self.jongCombo[String([ff, ch])] { f = m; return Edit(delete: true, insert: text) }
        reset(); c = ch; return Edit(delete: false, insert: String(ch))
    }

    /// 조합 중이면 한 단계 되돌리고 Edit을, 아니면 nil을 돌려준다.
    mutating func backspace() -> Edit? {
        guard isComposing else { return nil }
        if let ff = f {
            f = Self.split(ff, Self.jongCombo)?.0
        } else if let vv = v {
            v = Self.split(vv, Self.vowelCombo)?.0
        } else {
            c = nil
        }
        return Edit(delete: true, insert: text)
    }
}
