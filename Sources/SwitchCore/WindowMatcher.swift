import Foundation
import CoreGraphics

public struct WindowMatchCandidate {
    public let id: UInt32
    public let bounds: CGRect
    public let title: String?

    public init(id: UInt32, bounds: CGRect, title: String?) {
        self.id = id
        self.bounds = bounds
        self.title = title
    }
}

/// AX 与窗口服务器没有公开的统一编号；证据不足时不关联截图，避免把同名窗口配错。
public enum WindowMatcher {
    public static func matchAll(_ windows: [(id: String, bounds: CGRect, title: String)], candidates: [WindowMatchCandidate]) -> [String: UInt32] {
        var proposed: [String: UInt32] = [:]
        var claims: [UInt32: Int] = [:]
        for window in windows {
            if let id = match(bounds: window.bounds, title: window.title, candidates: candidates) {
                proposed[window.id] = id
                claims[id, default: 0] += 1
            }
        }
        return proposed.filter { claims[$0.value] == 1 }
    }

    /// 本轮没有读取几何的旧条目不能参与匹配，也不能继承上一轮的截图编号。
    public static func matchMeasured(_ windows: [(id: String, bounds: CGRect)], titlesThisScan: [String: String], candidates: [WindowMatchCandidate]) -> [String: UInt32] {
        matchAll(windows.compactMap { window in
            titlesThisScan[window.id].map { (window.id, window.bounds, $0) }
        }, candidates: candidates)
    }

    public static func match(bounds: CGRect, title: String, candidates: [WindowMatchCandidate]) -> UInt32? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nearby = candidates.filter { candidate in
            let rect = candidate.bounds
            let dx: CGFloat = abs(rect.minX - bounds.minX)
            let dy: CGFloat = abs(rect.minY - bounds.minY)
            let dw: CGFloat = abs(rect.width - bounds.width)
            let dh: CGFloat = abs(rect.height - bounds.height)
            return dx + dy + dw + dh < 8
        }
        let titled = title.isEmpty ? [] : nearby.filter { $0.title == title }
        // 有真实标题且明确矛盾时，几何相同也不是同一窗口的可靠证据。
        if !titled.isEmpty { return titled.count == 1 ? titled[0].id : nil }
        guard nearby.count == 1, title.isEmpty || (nearby[0].title ?? "").isEmpty else { return nil }
        return nearby[0].id
    }
}
