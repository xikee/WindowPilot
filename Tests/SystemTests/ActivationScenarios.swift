import AppKit

private struct CheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}

private final class TestClock {
    var now: TimeInterval = 0
    private var work: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ callback: @escaping () -> Void) { work.append((now + delay, callback)) }
    func advance(_ delta: TimeInterval) {
        let end = now + delta
        while let index = work.indices.filter({ work[$0].0 <= end }).min(by: { work[$0].0 < work[$1].0 }) {
            let next = work.remove(at: index)
            now = next.0
            next.1()
        }
        now = end
    }
}

private final class FakeBackend: WindowActivationBackend {
    var available = true
    var raiseResult = WindowRaiseResult.accepted
    var focused = false
    var holdRaise = false
    var holdFocus = false
    var raised: [ActivationRequest] = []
    var raiseCallbacks: [(WindowRaiseResult) -> Void] = []
    var focusCallbacks: [(Bool) -> Void] = []
    var reads = 0

    func prepare(_ window: WindowEntry) -> Bool { available }
    func raise(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (WindowRaiseResult) -> Void) {
        raised.append(request)
        if holdRaise { raiseCallbacks.append(completion) } else { completion(raiseResult) }
    }
    func isFocused(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (Bool) -> Void) {
        reads += 1
        if holdFocus { focusCallbacks.append(completion) } else { completion(focused) }
    }
}

@main enum ActivationChecks {
    static func main() {
        let window = WindowEntry(id: "target", windowID: nil, pid: 123, appName: "测试", title: "窗口",
                                 bounds: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: false, hidden: false, element: nil)
        func setup() -> (TestClock, FakeBackend, WindowActivator) {
            let clock = TestClock()
            let backend = FakeBackend()
            let activator = WindowActivator(backend: backend, now: { clock.now }, schedule: clock.schedule)
            return (clock, backend, activator)
        }
        let checks: [(String, () throws -> Void)] = [
            ("AX 接受但焦点未到时不能误报成功", {
                let (clock, backend, activator) = setup()
                var results: [WindowActivationResult] = []
                activator.activate(window) { results.append($0) }
                try require(results.isEmpty, "仅 raise 成功不能完成激活")
                backend.focused = true
                clock.advance(0.05)
                try require(results == [.confirmed], "焦点到达后才可成功")
                clock.advance(2)
                try require(results == [.confirmed], "截止回调不能重复完成")
            }),
            ("焦点一直不匹配会有界超时", {
                let (clock, backend, activator) = setup()
                var results: [WindowActivationResult] = []
                activator.activate(window) { results.append($0) }
                clock.advance(1.3)
                try require(results == [.timedOut], "应报告确认超时")
                let reads = backend.reads
                clock.advance(3)
                try require(backend.reads == reads && results.count == 1, "超时后不能继续轮询或重复回调")
            }),
            ("系统调用不回调仍可超时并丢弃迟到结果", {
                let (clock, backend, activator) = setup()
                backend.holdRaise = true
                var results: [WindowActivationResult] = []
                activator.activate(window) { results.append($0) }
                clock.advance(1.3)
                try require(results == [.timedOut] && backend.raised[0].isCancelled, "排队或阻塞也应结束事务")
                backend.raiseCallbacks[0](.invalidTarget)
                try require(backend.reads == 0 && results.count == 1, "迟到 raise 不能启动焦点确认")
            }),
            ("新激活淘汰旧请求及其迟到回调", {
                let (_, backend, activator) = setup()
                backend.holdRaise = true
                var first: [WindowActivationResult] = []
                var second: [WindowActivationResult] = []
                activator.activate(window) { first.append($0) }
                activator.activate(window) { second.append($0) }
                try require(first == [.superseded] && backend.raised[0].isCancelled, "旧请求必须取消")
                backend.raiseCallbacks[0](.invalidTarget)
                try require(backend.reads == 0, "旧请求不能确认或再次置前")
                backend.focused = true
                backend.raiseCallbacks[1](.accepted)
                try require(second == [.confirmed], "新请求必须独立完成")
            }),
            ("取消后迟到焦点不能恢复事务", {
                for raiseResult in [WindowRaiseResult.accepted, .rejected] {
                    let (clock, backend, activator) = setup()
                    backend.raiseResult = raiseResult
                    backend.holdFocus = true
                    var results: [WindowActivationResult] = []
                    activator.activate(window) { results.append($0) }
                    try require(backend.focusCallbacks.count == 1, "应已开始读取焦点")
                    activator.cancel()
                    backend.focusCallbacks[0](true)
                    clock.advance(2)
                    try require(results == [.superseded] && backend.raised[0].isCancelled && backend.reads == 1,
                                "取消后必须丢弃读回结果")
                }
            }),
            ("系统拒绝后只读一次，按实际焦点完成", {
                for focused in [true, false] {
                    let (clock, backend, activator) = setup()
                    backend.raiseResult = .rejected
                    backend.focused = focused
                    var results: [WindowActivationResult] = []
                    activator.activate(window) { results.append($0) }
                    try require(results == [focused ? .confirmed : .rejected], "单次读回后应立即完成")
                    clock.advance(2)
                    try require(backend.raised.count == 1 && backend.reads == 1 && results.count == 1, "拒绝后不能重试")
                }
            }),
            ("拒绝后的焦点读回受截止时间约束", {
                let (clock, backend, activator) = setup()
                backend.raiseResult = .rejected
                backend.holdFocus = true
                var results: [WindowActivationResult] = []
                activator.activate(window) { results.append($0) }
                try require(backend.focusCallbacks.count == 1 && results.isEmpty, "应等待单次焦点回调")
                // 模拟截止时间已到，但主队列上的定时任务还未执行。
                clock.now = 1.2
                backend.focusCallbacks[0](true)
                try require(results == [.timedOut] && backend.raised[0].isCancelled, "迟到的焦点不能覆盖超时")
                clock.advance(2)
                try require(results == [.timedOut] && backend.reads == 1, "定时任务不能重复完成")
            }),
            ("只有目标窗口明确失效才通知调用方淘汰", {
                let (_, backend, activator) = setup()
                var results: [WindowActivationResult] = []
                for (error, onTarget, expected) in [
                    (AXError.invalidUIElement, true, WindowActivationResult.invalidTarget),
                    (.invalidUIElement, false, .rejected),
                    (.cannotComplete, true, .rejected),
                    (.actionUnsupported, true, .rejected)
                ] {
                    backend.raiseResult = WindowRaiseResult(error, onTargetWindow: onTarget)
                    let previousReads = backend.reads
                    results.removeAll()
                    activator.activate(window) { results.append($0) }
                    try require(results == [expected], "AX 错误 \(error) 的归属或分类错误")
                    try require(backend.reads - previousReads == (expected == .invalidTarget ? 0 : 1), "焦点读取次数错误")
                }
                backend.available = false
                results.removeAll()
                activator.activate(window) { results.append($0) }
                try require(results == [.unavailable], "准备失败应保留不可用结果")
            })
        ]
        var failures = 0
        for (name, check) in checks {
            do { try check(); print("✓ \(name)") }
            catch { failures += 1; print("✗ \(name): \(error)") }
        }
        print("\(checks.count - failures)/\(checks.count) 个激活场景通过")
        if failures > 0 { exit(1) }
    }
}
