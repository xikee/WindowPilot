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
        let matches = titled.isEmpty ? nearby : titled
        return matches.count == 1 ? matches[0].id : nil
    }
}
