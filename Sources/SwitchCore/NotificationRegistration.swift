/// 每个窗口独立维护通知注册状态。调用方在主线程上推进状态，系统 IPC 在后台执行。
public struct NotificationRegistration {
    private var settled = Set<String>()
    private var busy = false
    private var retryAt: Double = 0
    public init() {}

    public mutating func begin(_ names: [String], now: Double) -> [String] {
        guard !busy, now >= retryAt else { return [] }
        let missing = names.filter { !settled.contains($0) }
        busy = !missing.isEmpty
        return missing
    }

    public mutating func finish(settled names: [String], now: Double) {
        settled.formUnion(names)
        retryAt = now + 5
        busy = false
    }
}
