import Foundation
import QuartzCore

/// 키보드 성능 측정. 디버그 빌드에서만 기록하고, 앱의 "키보드 성능 측정"에서 본다. (배포 빌드에서는 아무 일도 하지 않는다)
final class Metrics {
    static let shared = Metrics()
    var meta: [String: String] = [:]

    #if DEBUG
    private var samples: [String: [Double]] = [:]
    private var counters: [String: Int] = [:]
    private var lastFlush = CACurrentMediaTime()
    private var lastReset = Double(Bridge.get(Bridge.Key.metricsReset)) ?? 0
    private var dirty = 0
    #endif

    @inline(__always)
    func time<T>(_ name: String, _ block: () -> T) -> T {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        let r = block()
        record(name, (CACurrentMediaTime() - t0) * 1000)
        return r
        #else
        return block()
        #endif
    }

    func record(_ name: String, _ ms: Double) {
        #if DEBUG
        var a = samples[name, default: []]
        a.append(ms)
        if a.count > 1500 { a.removeFirst(500) }
        samples[name] = a
        dirty += 1
        flush(force: false)
        #endif
    }

    func bump(_ name: String) {
        #if DEBUG
        counters[name, default: 0] += 1
        #endif
    }

    func flush(force: Bool) {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard force || (dirty >= 40 && now - lastFlush > 1.5) else { return }
        lastFlush = now; dirty = 0
        if let r = Double(Bridge.get(Bridge.Key.metricsReset)), r > lastReset {   // 앱에서 초기화를 눌렀다
            lastReset = r; samples = [:]; counters = [:]
        }
        var out: [String: Any] = ["meta": meta, "counters": counters, "updated": Date().timeIntervalSince1970]
        var stats: [String: [String: Double]] = [:]
        for (k, a) in samples where !a.isEmpty {
            let s = a.sorted()
            func pct(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
            stats[k] = ["n": Double(a.count), "avg": a.reduce(0, +) / Double(a.count), "p50": pct(0.5), "p95": pct(0.95), "max": s.last!]
        }
        out["stats"] = stats
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
           let str = String(data: d, encoding: .utf8) { Bridge.set(str, Bridge.Key.metrics) }
        #endif
    }
}
