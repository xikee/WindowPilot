/// 记录哪些窗口已获得一次检查机会。未轮到与查过但没有窗口是两种状态。
public struct CatalogCoverage: Equatable {
    private var inspected: [Int32: Set<String>] = [:]
    private var complete = Set<Int32>()
    private var unavailable = Set<Int32>()
    private var unreadable: [Int32: Set<String>] = [:]

    public init() {}

    public mutating func retain(_ live: Set<Int32>) {
        inspected = inspected.filter { live.contains($0.key) }
        unreadable = unreadable.filter { live.contains($0.key) }
        complete.formIntersection(live)
        unavailable.formIntersection(live)
    }

    public mutating func listed(_ pid: Int32, ids: Set<String>, checked: Set<String>, failed: Set<String> = []) {
        let missing = (unreadable[pid] ?? []).intersection(ids).subtracting(checked).union(failed)
        unreadable[pid] = missing.isEmpty ? nil : missing
        let seen = (inspected[pid] ?? []).intersection(ids).union(checked)
        inspected[pid] = seen
        unavailable.remove(pid)
        if ids.isSubset(of: seen) { complete.insert(pid) } else { complete.remove(pid) }
    }

    public mutating func failed(_ pid: Int32) {
        complete.remove(pid)
        unavailable.insert(pid)
    }

    public func pending(in scope: Set<Int32>) -> Set<Int32> { scope.subtracting(complete).subtracting(unavailable) }
    public func hasUnavailable(in scope: Set<Int32>) -> Bool { !scope.isDisjoint(with: unavailable) || !scope.isDisjoint(with: unreadable.keys) }
}
