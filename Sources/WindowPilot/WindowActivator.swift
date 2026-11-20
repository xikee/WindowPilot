import AppKit
import ApplicationServices

/// 取消只阻止尚未执行的系统动作；已经进入 AX 的调用仍由系统完成。
final class ActivationRequest {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

enum WindowActivationResult: String {
    case confirmed, unavailable, rejected, timedOut, superseded
}

/// 回调统一回到主队列；系统调用由实现安排到后台，测试可以替换整个边界。
protocol WindowActivationBackend {
    func prepare(_ window: WindowEntry) -> Bool
    func raise(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (Bool) -> Void)
    func isFocused(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (Bool) -> Void)
}

final class AccessibilityActivationBackend: WindowActivationBackend {
    private let queue = DispatchQueue(label: "app.windowpilot.activation", qos: .userInteractive)

    func prepare(_ window: WindowEntry) -> Bool {
        guard window.element != nil, let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { return false }
        if app.isHidden, !app.unhide() { return false }
        return app.isActive || app.activate(options: [])
    }

    func raise(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard !request.isCancelled, let element = window.element else { DispatchQueue.main.async { completion(false) }; return }
            AXUIElementSetMessagingTimeout(element, 0.10)
            var minimized: CFTypeRef?
            let code = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
            if (code == .success ? minimized as? Bool : window.minimized) == true, !request.isCancelled {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            guard !request.isCancelled else { DispatchQueue.main.async { completion(false) }; return }
            let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            var success = result == .success
            if !success, !request.isCancelled {
                let app = AXUIElementCreateApplication(window.pid)
                AXUIElementSetMessagingTimeout(app, 0.10)
                success = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element) == .success
            }
            let accepted = success
            DispatchQueue.main.async { completion(accepted) }
        }
    }

    func isFocused(_ window: WindowEntry, request: ActivationRequest, completion: @escaping (Bool) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { completion(false); return }
        queue.async {
            guard !request.isCancelled, let target = window.element else { DispatchQueue.main.async { completion(false) }; return }
            let app = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(app, 0.06)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
            let matches = result == .success && value.map { CFEqual($0, target) } == true
            DispatchQueue.main.async {
                completion(matches && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid)
            }
        }
    }
}

/// 一次激活必须读回目标焦点才算成功；新请求使旧请求失效，超时不会再次置前窗口。
final class WindowActivator {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private let backend: WindowActivationBackend
    private let schedule: Schedule
    private let now: () -> TimeInterval
    private let timeout: TimeInterval
    private var current: ActivationRequest?
    private var pendingCompletion: ((WindowActivationResult) -> Void)?

    init(backend: WindowActivationBackend = AccessibilityActivationBackend(), timeout: TimeInterval = 1.2,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.backend = backend
        self.timeout = timeout
        self.now = now
        self.schedule = schedule
    }

    func cancel() { if let current { finish(current, .superseded) } }

    func activate(_ window: WindowEntry, completion: @escaping (WindowActivationResult) -> Void) {
        cancel()
        let request = ActivationRequest()
        current = request
        pendingCompletion = completion
        let deadline = now() + timeout
        schedule(timeout) { [weak self] in self?.finish(request, .timedOut) }
        guard backend.prepare(window) else { finish(request, .unavailable); return }
        backend.raise(window, request: request) { [weak self] accepted in
            guard let self, self.current === request else { return }
            guard accepted else { self.finish(request, .rejected); return }
            self.verify(window, request: request, deadline: deadline)
        }
    }

    private func verify(_ window: WindowEntry, request: ActivationRequest, deadline: TimeInterval) {
        guard current === request else { return }
        guard now() < deadline else { finish(request, .timedOut); return }
        backend.isFocused(window, request: request) { [weak self] focused in
            guard let self, self.current === request else { return }
            guard self.now() < deadline else { self.finish(request, .timedOut); return }
            if focused { self.finish(request, .confirmed) }
            else { self.schedule(0.04) { [weak self] in self?.verify(window, request: request, deadline: deadline) } }
        }
    }

    private func finish(_ request: ActivationRequest, _ result: WindowActivationResult) {
        guard current === request else { return }
        request.cancel()
        let completion = pendingCompletion
        current = nil
        pendingCompletion = nil
        completion?(result)
    }
}
