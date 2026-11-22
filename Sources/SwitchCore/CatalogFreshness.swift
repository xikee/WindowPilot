import Foundation

/// 记录窗口最后得到存在性确认的单调时间；这不是其几何位置的验证时间。
public struct CatalogFreshness {
    public let lifetime: TimeInterval
    private var validated: [String: TimeInterval] = [:]

    public init(lifetime: TimeInterval = 6) { self.lifetime = max(0, lifetime) }

    public mutating func record(_ id: String, at time: TimeInterval) { validated[id] = time }

    public func isFresh(_ id: String, at time: TimeInterval) -> Bool {
        guard let last = validated[id] else { return false }
        return time >= last && time - last <= lifetime
    }

    public mutating func retain(_ ids: Set<String>) {
        validated = validated.filter { ids.contains($0.key) }
    }
}
