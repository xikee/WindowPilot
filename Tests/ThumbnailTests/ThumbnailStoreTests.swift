import AppKit

// 独立测试只提供 ThumbnailStore 使用的条目字段；应用中的真实类型由集成构建验证。
// 避免把窗口扫描服务及其异步系统 API 链入缩略图单元测试。
struct WindowEntry {
    let id: String
    let windowID: CGWindowID?
    let minimized: Bool
    let hidden: Bool
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private final class TestScheduler {
    private struct Work {
        let deadline: TimeInterval
        let order: Int
        let run: () -> Void
    }
    private var work: [Work] = []
    private var order = 0
    private var now: TimeInterval = 0

    func schedule(_ delay: TimeInterval, _ run: @escaping () -> Void) {
        order += 1
        work.append(Work(deadline: now + delay, order: order, run: run))
    }

    func advance(_ interval: TimeInterval) {
        let end = now + interval
        while let next = work.indices.min(by: {
            work[$0].deadline == work[$1].deadline ? work[$0].order < work[$1].order : work[$0].deadline < work[$1].deadline
        }), work[next].deadline <= end {
            let task = work.remove(at: next)
            now = task.deadline
            task.run()
        }
        now = end
    }
}

private final class TestBackend: ThumbnailBackend {
    let requiresEnumeration: Bool
    private(set) var enumerationCount = 0
    private(set) var captureIDs: [CGWindowID] = []
    private(set) var enumerationCallbacks: [([ThumbnailTarget]) -> Void] = []
    private(set) var captureCallbacks: [(CGImage?) -> Void] = []
    private(set) var maximumInFlight = 0
    var inFlight: Int { enumerationCallbacks.count + captureCallbacks.count }

    init(enumeration: Bool) { requiresEnumeration = enumeration }

    func enumerate(_ completion: @escaping ([ThumbnailTarget]) -> Void) {
        enumerationCount += 1
        enumerationCallbacks.append(completion)
        maximumInFlight = max(maximumInFlight, inFlight)
    }

    func capture(_ target: ThumbnailTarget, completion: @escaping (CGImage?) -> Void) {
        captureIDs.append(target.windowID)
        captureCallbacks.append(completion)
        maximumInFlight = max(maximumInFlight, inFlight)
    }

    func finishEnumeration(_ ids: [CGWindowID]) {
        enumerationCallbacks.removeFirst()(ids.map { ThumbnailTarget(windowID: $0) })
    }

    func finishCapture(_ image: CGImage?) {
        captureCallbacks.removeFirst()(image)
    }
}

private func entry(_ id: CGWindowID, minimized: Bool = false, hidden: Bool = false) -> WindowEntry {
    WindowEntry(id: String(id), windowID: id, minimized: minimized, hidden: hidden)
}

private func testImage(height: Int = 4) -> CGImage {
    let context = CGContext(data: nil, width: 4, height: height, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}

private final class Harness {
    let scheduler = TestScheduler()
    let backend: TestBackend
    let store: ThumbnailStore
    var presentation = UUID()

    init(enumeration: Bool = false, maxImages: Int = 48, maxBytes: Int = 32 * 1024 * 1024) {
        backend = TestBackend(enumeration: enumeration)
        var policy = ThumbnailPolicy()
        policy.maxCachedImages = maxImages
        policy.maxCachedBytes = maxBytes
        let scheduler = self.scheduler
        store = ThumbnailStore(backend: backend, policy: policy, schedule: scheduler.schedule)
    }

    func open(_ ids: [CGWindowID], selected: CGWindowID? = nil, enabled: Bool = true) {
        presentation = UUID()
        store.begin(presentation, enabled: enabled)
        for id in ids { store.request(entry(id), presentation: presentation) }
        store.prioritize(selected.map(String.init))
        store.panelDidShow()
        scheduler.advance(0.11)
    }

    func flush() { scheduler.advance(0.05) }
}

@main
private enum ThumbnailTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("枚举超时丢弃迟到结果且不重复枚举", enumerationTimeout),
            ("枚举跨会话保留原生槽位并隔离 request id", enumerationAcrossSessions),
            ("截图超时不扩张原生在途队列", captureTimeout),
            ("卡住的截图跨 clear/new session 与开关保持限流", captureAcrossSessions),
            ("正常成功推进、可见项与选择优先", normalProgress),
            ("数量上限保护可见项且离屏淘汰后可重拍", countCapacity),
            ("待发布图片也计入容量", pendingCapacity),
            ("字节预算用尽后随窗口离屏恢复", byteCapacity),
            ("空间不足时保留缓存并暂停重试", insufficientReclaimableBytes),
            ("单图超预算时在本会话内降级", oversizedImage),
            ("clear 隔离待发布图片和旧定时任务", pendingFlushAcrossSessions),
            ("禁用、展示延迟和失败降级", enableAndFailure)
        ]
        do {
            try expect(Thread.isMainThread, "测试必须在主线程运行")
            for (name, run) in tests {
                try run()
                print("PASS \(name)")
            }
            print("缩略图测试全部通过：\(tests.count) 项")
        } catch {
            fputs("FAIL \(error)\n", stderr)
            exit(1)
        }
    }

    private static func enumerationTimeout() throws {
        let h = Harness(enumeration: true)
        h.open([1, 2])
        try expect(h.backend.enumerationCount == 1, "应启动前置枚举")
        h.scheduler.advance(1.01)
        for _ in 0..<50 { h.store.prioritize("2") }
        try expect(h.backend.inFlight == 1 && h.backend.enumerationCount == 1, "枚举超时不得释放原生槽位或重试")
        h.backend.finishEnumeration([1, 2])
        h.flush()
        try expect(h.backend.captureIDs.isEmpty && h.store.images.isEmpty, "超时枚举的迟到结果必须丢弃并保留图标降级")
        try expect(h.backend.inFlight == 0, "真实回调应释放原生槽位")
    }

    private static func enumerationAcrossSessions() throws {
        let h = Harness(enumeration: true)
        h.open([1])
        let stale = h.backend.enumerationCallbacks[0]
        let oldPresentation = h.presentation
        h.store.clear()
        for id: CGWindowID in 2...20 { h.open([id]) }
        h.scheduler.advance(10)
        try expect(h.backend.enumerationCount == 1 && h.backend.inFlight == 1, "新会话不能绕过旧枚举的原生槽位")
        h.store.request(entry(1), presentation: oldPresentation)
        h.backend.finishEnumeration([1])
        try expect(h.backend.enumerationCount == 2 && h.backend.captureIDs.isEmpty, "旧枚举结束后应为当前会话重新枚举")
        stale([ThumbnailTarget(windowID: 1)])
        try expect(h.backend.inFlight == 1 && h.backend.enumerationCount == 2, "旧 request id 的重复回调不得释放新请求")
        h.backend.finishEnumeration([20])
        try expect(h.backend.captureIDs == [20], "只能截图当前会话窗口")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["20"], "旧会话结果不得污染新会话")
        try expect(h.backend.maximumInFlight == 1, "枚举和截图的总原生并发必须有界")
    }

    private static func captureTimeout() throws {
        let h = Harness()
        h.open([1, 2])
        h.scheduler.advance(2)
        for id: CGWindowID in 3...100 {
            h.store.request(entry(id), presentation: h.presentation)
            h.store.prioritize(String(id))
            h.scheduler.advance(2)
        }
        try expect(h.backend.captureIDs == [1] && h.backend.inFlight == 1, "逻辑超时后不得持续启动或排队截图")
        try expect(h.store.images.isEmpty, "超时应保持图标降级")
        h.backend.finishCapture(testImage())
        try expect(h.backend.captureIDs == [1, 100], "原生结束后应继续当前选择的可见窗口")
        try expect(h.store.images["1"] == nil, "超时后的迟到图片必须丢弃")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(h.store.images["100"] != nil && h.backend.maximumInFlight == 1, "恢复后应成功发布且原生始终最多一个在途")
    }

    private static func captureAcrossSessions() throws {
        let h = Harness()
        h.open([1])
        let stale = h.backend.captureCallbacks[0]
        h.store.clear()
        for id: CGWindowID in 2...30 { h.open([id]) }
        h.store.setEnabled(false)
        h.store.setEnabled(true)
        h.scheduler.advance(10)
        try expect(h.backend.captureIDs == [1] && h.backend.inFlight == 1, "清理、新会话和开关不能释放仍在运行的截图")
        try expect(h.store.images.isEmpty, "每个新会话都必须清空图片")
        h.backend.finishCapture(testImage())
        try expect(h.backend.captureIDs == [1, 30], "旧截图结束后应推进当前会话")
        stale(testImage())
        try expect(h.backend.captureIDs == [1, 30] && h.backend.inFlight == 1, "旧截图 request id 不得释放当前截图")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["30"], "旧图片不得在 clear 后重新出现")
        try expect(h.backend.maximumInFlight == 1, "跨会话真实并发不得增长")
    }

    private static func normalProgress() throws {
        let h = Harness(enumeration: true)
        h.open([1, 2, 3], selected: 3)
        h.backend.finishEnumeration([1, 2, 3])
        try expect(h.backend.captureIDs == [3], "选择项应优先")
        h.store.remove("2", presentation: h.presentation)
        h.backend.finishCapture(testImage())
        try expect(h.backend.captureIDs == [3, 1], "成功后应推进下一个仍可见窗口")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["1", "3"], "正常图片应合并发布")
        h.store.request(entry(2), presentation: h.presentation)
        try expect(h.backend.captureIDs == [3, 1, 2], "尚未尝试的窗口重新可见后可截图")
        h.backend.finishCapture(nil)
        h.store.remove("2", presentation: h.presentation)
        h.store.request(entry(2), presentation: h.presentation)
        try expect(h.backend.captureIDs.count == 3 && h.store.images["2"] == nil, "失败窗口应降级且同一会话不反复重试")
    }

    private static func countCapacity() throws {
        let h = Harness(maxImages: 2)
        h.open([1, 2, 3])
        h.backend.finishCapture(testImage())
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(h.backend.captureIDs == [1, 2], "可见图片占满缓存时应暂停新截图")
        try expect(Set(h.store.images.keys) == ["1", "2"], "可见图片不得被容量策略淘汰")
        h.store.remove("1", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 3], "存在离屏项后应继续截图")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["2", "3"], "只淘汰离屏项且严格遵守数量上限")
        h.store.request(entry(1), presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 3], "滚回时不能为重拍淘汰仍可见的图片")
        h.store.remove("3", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 3, 1], "已淘汰项滚回且有离屏容量后应允许重拍")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["1", "2"], "重拍结果应恢复，并只淘汰离屏图片")
        for _ in 0..<50 {
            h.store.remove("1", presentation: h.presentation)
            h.store.request(entry(1), presentation: h.presentation)
            h.store.prioritize("1")
        }
        try expect(h.backend.captureIDs == [1, 2, 3, 1], "已有缓存的窗口反复出现不得重复截图")
        h.store.request(entry(3), presentation: h.presentation)
        h.store.remove("1", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 3, 1, 3], "再次滚回另一个已淘汰项也应恢复截图资格")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["2", "3"], "持续可见项应始终受到保护")
        try expect(h.backend.maximumInFlight == 1, "滚回重拍仍须遵守原生在途限制")
        h.open([1])
        try expect(h.backend.captureIDs == [1, 2, 3, 1, 3, 1] && h.store.images.isEmpty, "新会话应清空缓存并允许重新截图")
    }

    private static func pendingCapacity() throws {
        let h = Harness(maxImages: 2)
        h.open([1, 2, 3])
        h.store.remove("1", presentation: h.presentation)
        h.backend.finishCapture(testImage())
        h.store.remove("2", presentation: h.presentation)
        h.backend.finishCapture(testImage())
        h.backend.finishCapture(testImage())
        try expect(h.store.images.isEmpty, "批量发布前应保留合并行为")
        h.flush()
        try expect(Set(h.store.images.keys) == ["2", "3"], "待发布图片必须共享容量并优先淘汰最早离屏项")
    }

    private static func byteCapacity() throws {
        let image = testImage()
        let bytes = image.bytesPerRow * image.height
        let h = Harness(maxImages: 10, maxBytes: bytes)
        h.open([1, 2])
        h.backend.finishCapture(image)
        h.flush()
        for _ in 0..<50 { h.store.prioritize("2") }
        try expect(h.backend.captureIDs == [1] && h.backend.inFlight == 0, "可见图片用尽字节预算后应暂停截图")
        h.store.remove("1", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2], "窗口离屏后应自动为等待窗口截图")
        h.backend.finishCapture(image)
        h.flush()
        try expect(Set(h.store.images.keys) == ["2"], "等待窗口应在同一会话内恢复图片")
        h.store.request(entry(1), presentation: h.presentation)
        h.store.remove("2", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 1], "因字节预算淘汰的图片滚回后应可重拍")
        h.backend.finishCapture(image)
        h.flush()
        try expect(Set(h.store.images.keys) == ["1"], "重拍应恢复图片并遵守字节预算")
    }

    private static func insufficientReclaimableBytes() throws {
        let small = testImage(height: 1)
        let large = testImage(height: 3)
        let h = Harness(maxBytes: large.bytesPerRow * large.height + 2 * small.bytesPerRow)
        h.open([1, 2, 3, 4])
        h.backend.finishCapture(large)
        h.backend.finishCapture(small)
        h.flush()
        h.store.remove("2", presentation: h.presentation)
        h.backend.finishCapture(large)
        try expect(h.backend.captureIDs == [1, 2, 3, 4], "窗口 3 等待容量时应继续处理窗口 4")
        h.backend.finishCapture(large)
        for _ in 0..<50 {
            h.store.request(entry(2), presentation: h.presentation)
            h.store.remove("2", presentation: h.presentation)
            h.store.prioritize("4")
        }
        h.scheduler.advance(10)
        try expect(Set(h.store.images.keys) == ["1", "2"], "可回收空间不足时应保留离屏缓存")
        try expect(h.backend.captureIDs == [1, 2, 3, 4] && h.backend.inFlight == 0, "容量仍不足时调度和计时器都不得重试")
        h.store.remove("1", presentation: h.presentation)
        try expect(h.backend.captureIDs == [1, 2, 3, 4, 4], "足够空间出现后应优先重拍选中的等待窗口")
        h.backend.finishCapture(large)
        h.flush()
        try expect(h.store.images["4"] != nil && h.store.images["3"] == nil, "恢复后应发布选中窗口的图片")
        try expect(h.backend.inFlight == 0 && h.backend.maximumInFlight == 1, "其余窗口应继续等待且最多一个截图在途")
    }

    private static func oversizedImage() throws {
        let image = testImage()
        let small = Harness(maxBytes: image.bytesPerRow * image.height - 1)
        small.open([1, 2])
        small.backend.finishCapture(image)
        small.backend.finishCapture(testImage(height: 1))
        small.store.remove("2", presentation: small.presentation)
        small.store.remove("1", presentation: small.presentation)
        small.store.request(entry(1), presentation: small.presentation)
        small.flush()
        try expect(Set(small.store.images.keys) == ["2"] && small.backend.captureIDs == [1, 2], "单图超预算后容量或可见性变化都不得触发重拍")
        let zero = Harness(maxImages: 0)
        zero.open([1])
        try expect(zero.backend.captureIDs.isEmpty, "零容量不应启动截图")
    }

    private static func pendingFlushAcrossSessions() throws {
        let h = Harness()
        h.open([1])
        h.backend.finishCapture(testImage())
        try expect(h.store.images.isEmpty, "图片应等待批量发布")
        h.store.clear()
        h.open([2])
        try expect(h.store.images.isEmpty, "旧会话待发布图片不得泄漏")
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(Set(h.store.images.keys) == ["2"], "新会话 flush 不得被旧定时任务影响")
        h.store.clear()
        h.scheduler.advance(10)
        try expect(h.store.images.isEmpty, "清理后所有旧定时任务应失效")
    }

    private static func enableAndFailure() throws {
        let h = Harness()
        h.open([1], enabled: false)
        h.scheduler.advance(10)
        try expect(h.backend.captureIDs.isEmpty, "禁用缩略图不得启动原生调用")
        h.store.setEnabled(true)
        h.scheduler.advance(0.05)
        try expect(h.backend.captureIDs.isEmpty, "展示延迟前不得截图")
        h.scheduler.advance(0.06)
        try expect(h.backend.captureIDs == [1], "展示延迟后应开始")
        h.store.request(entry(2, minimized: true), presentation: h.presentation)
        h.store.request(entry(3, hidden: true), presentation: h.presentation)
        h.backend.finishCapture(nil)
        try expect(h.backend.captureIDs == [1] && h.store.images.isEmpty, "隐藏、最小化和失败窗口应保留图标降级")
        h.store.setEnabled(false)
        h.store.setEnabled(true)
        h.scheduler.advance(0.11)
        h.backend.finishCapture(testImage())
        h.flush()
        try expect(h.store.images["1"] != nil, "重新启用应使用新 generation")
        h.store.setEnabled(false)
        try expect(h.store.images.isEmpty, "关闭缩略图必须立即清除图片")
    }
}
