import AppKit
import ScreenCaptureKit

struct ThumbnailTarget {
    let windowID: CGWindowID
    var window: SCWindow? = nil
}

// 回调必须回到主线程。测试后端可以直接、确定性地交付结果。
protocol ThumbnailBackend {
    var requiresEnumeration: Bool { get }
    func enumerate(_ completion: @escaping ([ThumbnailTarget]) -> Void)
    func capture(_ target: ThumbnailTarget, completion: @escaping (CGImage?) -> Void)
}

struct ThumbnailPolicy {
    var enumerationTimeout: TimeInterval = 1
    var captureTimeout: TimeInterval = 1
    var presentationDelay: TimeInterval = 0.10
    var flushDelay: TimeInterval = 0.045
    var maxCachedImages = 48
    var maxCachedBytes = 32 * 1024 * 1024
}

private final class SystemThumbnailBackend: ThumbnailBackend {
    private let queue = DispatchQueue(label: "app.windowpilot.thumbnails", qos: .utility)

    var requiresEnumeration: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    func enumerate(_ completion: @escaping ([ThumbnailTarget]) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            let targets = (content?.windows ?? []).map { ThumbnailTarget(windowID: $0.windowID, window: $0) }
            DispatchQueue.main.async { completion(targets) }
        }
    }

    func capture(_ target: ThumbnailTarget, completion: @escaping (CGImage?) -> Void) {
        if #available(macOS 14.0, *) {
            guard let window = target.window else { completion(nil); return }
            let config = SCStreamConfiguration()
            config.width = 560
            config.height = max(1, min(1120, Int(560 * window.frame.height / max(1, window.frame.width))))
            config.showsCursor = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) { image, _ in
                DispatchQueue.main.async { completion(image) }
            }
        } else {
            queue.async {
                let image = Self.captureLegacy(target.windowID)
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    @available(macOS, introduced: 13.0, obsoleted: 14.0)
    private static func captureLegacy(_ id: CGWindowID) -> CGImage? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        let scale = min(1, min(560 / Double(max(1, image.width)), 1120 / Double(max(1, image.height))))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private struct CachedImage {
        let image: NSImage
        let bytes: Int
        var access: UInt64
    }
    private let backend: ThumbnailBackend
    private let policy: ThumbnailPolicy
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = UUID()
    private var presentation: UUID?
    // 原生操作不能取消。这个槽位跨 clear/begin 保留，只有真实回调才能释放。
    // 枚举与截图共享一个槽位，原生卡住时不会往串行队列或系统服务追加任务。
    private var nativeRequest: UUID?
    private var enumerationRequest: UUID?
    private var activeCapture: UUID?
    private var visible: [WindowEntry] = []
    private var unavailable = Set<String>()
    // 保留上次截图的大小，容量不足或图片被淘汰后据此判断何时可以重拍。
    private var requiredBytes: [String: Int] = [:]
    private var cache: [String: CachedImage] = [:]
    private var cachedBytes = 0
    private var access: UInt64 = 0
    private var flushScheduled = false
    private var selectedID: String?
    private var available: [CGWindowID: ThumbnailTarget]?
    private var enabled = false
    private var shown = false
    private var ready = false

    init(backend: ThumbnailBackend? = nil, policy: ThumbnailPolicy = ThumbnailPolicy(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.backend = backend ?? SystemThumbnailBackend()
        self.policy = policy
        self.schedule = schedule
    }

    func begin(_ presentation: UUID, enabled: Bool) {
        clear()
        self.presentation = presentation
        self.enabled = enabled
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled { schedulePreviews() }
        else { resetImages() }
    }

    func panelDidShow() {
        guard !shown else { return }
        shown = true
        schedulePreviews()
    }

    func request(_ window: WindowEntry, presentation: UUID) {
        guard self.presentation == presentation, window.windowID != nil, !window.minimized, !window.hidden,
              !visible.contains(where: { $0.id == window.id }) else { return }
        visible.append(window)
        if cache[window.id] != nil {
            access &+= 1
            cache[window.id]?.access = access
        }
        pump()
    }

    func remove(_ id: String, presentation: UUID) {
        guard self.presentation == presentation else { return }
        visible.removeAll { $0.id == id }
        pump()
    }

    func prioritize(_ id: String?) {
        selectedID = id
        pump()
    }

    private func schedulePreviews() {
        guard enabled, shown, !ready else { return }
        let token = generation
        // 快速切换通常已经结束；只有留在屏幕上的面板才需要截图。
        schedule(policy.presentationDelay) { [weak self] in
            guard let self, self.generation == token, self.enabled, self.shown else { return }
            self.ready = true
            self.pump()
        }
    }

    // 离屏缓存可以回收，只有仍可见的图片会占用下一张截图的容量。
    private var capacityAfterEviction: (slots: Int, bytes: Int) {
        visible.reduce(into: (slots: policy.maxCachedImages, bytes: policy.maxCachedBytes)) { capacity, entry in
            if let cached = cache[entry.id] {
                capacity.slots -= 1
                capacity.bytes -= cached.bytes
            }
        }
    }

    private func pump() {
        guard enabled, ready, nativeRequest == nil else { return }
        let capacity = capacityAfterEviction
        guard capacity.slots > 0, capacity.bytes > 0 else { return }
        var candidates = visible.filter { entry in
            cache[entry.id] == nil && !unavailable.contains(entry.id) && (requiredBytes[entry.id] ?? 1) <= capacity.bytes
        }
        guard !candidates.isEmpty else { return }
        if let index = candidates.firstIndex(where: { $0.id == selectedID }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        if backend.requiresEnumeration, available == nil {
            enumerate()
            return
        }
        for entry in candidates {
            guard let id = entry.windowID else { continue }
            let target: ThumbnailTarget
            if backend.requiresEnumeration {
                guard let found = available?[id] else {
                    unavailable.insert(entry.id)
                    continue
                }
                target = found
            } else {
                target = ThumbnailTarget(windowID: id)
            }
            capture(target, entry: entry)
            return
        }
    }

    private func enumerate() {
        let token = generation
        let request = UUID()
        nativeRequest = request
        enumerationRequest = request
        schedule(policy.enumerationTimeout) { [weak self] in
            guard let self, self.generation == token, self.enumerationRequest == request else { return }
            self.enumerationRequest = nil
            self.available = [:]
            Diagnostics.shared.record("thumbnailEnumerationUnavailable", ["reason": "timeout"])
            // 保留 nativeRequest；迟到结果既不能恢复本会话，也不能污染新会话。
        }
        backend.enumerate { [weak self] targets in
            guard let self, self.nativeRequest == request else { return }
            self.nativeRequest = nil
            if self.generation == token, self.enumerationRequest == request {
                self.enumerationRequest = nil
                self.available = targets.reduce(into: [:]) { $0[$1.windowID] = $1 }
            }
            self.pump()
        }
    }

    private func capture(_ target: ThumbnailTarget, entry: WindowEntry) {
        let token = generation
        let request = UUID()
        nativeRequest = request
        activeCapture = request
        schedule(policy.captureTimeout) { [weak self] in
            guard let self, self.generation == token, self.activeCapture == request else { return }
            self.activeCapture = nil
            self.unavailable.insert(entry.id)
            Diagnostics.shared.record("thumbnailUnavailable", ["window": entry.windowID ?? 0, "reason": "timeout"])
            // 逻辑超时只显示图标。真实回调之前绝不能启动下一个原生操作。
        }
        backend.capture(target) { [weak self] image in
            guard let self, self.nativeRequest == request else { return }
            self.nativeRequest = nil
            if self.generation == token, self.activeCapture == request {
                self.activeCapture = nil
                if let image {
                    self.cacheImage(image, for: entry.id)
                    Diagnostics.shared.record("thumbnail", ["window": entry.windowID ?? 0, "width": image.width, "height": image.height])
                } else {
                    self.unavailable.insert(entry.id)
                    Diagnostics.shared.record("thumbnailUnavailable", ["window": entry.windowID ?? 0])
                }
            }
            self.pump()
        }
    }

    private func cacheImage(_ image: CGImage, for id: String) {
        let (bytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, bytes <= policy.maxCachedBytes else {
            unavailable.insert(id)
            return
        }
        requiredBytes[id] = bytes
        let capacity = capacityAfterEviction
        guard capacity.slots > 0, bytes <= capacity.bytes else { return }
        let visibleIDs = Set(visible.map(\.id))
        while cache.count >= policy.maxCachedImages || cachedBytes > policy.maxCachedBytes - bytes {
            guard let victim = cache.filter({ !visibleIDs.contains($0.key) }).min(by: { $0.value.access < $1.value.access })?.key else { return }
            cachedBytes -= cache.removeValue(forKey: victim)!.bytes
            // 已发布图片和待发布图片共用容量；及时释放已发布的离屏图片。
            if images[victim] != nil { images.removeValue(forKey: victim) }
        }
        access &+= 1
        cache[id] = CachedImage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), bytes: bytes, access: access)
        cachedBytes += bytes
        scheduleFlush(generation)
    }

    private func scheduleFlush(_ token: UUID) {
        guard !flushScheduled else { return }
        flushScheduled = true
        // 合并相邻截图，避免每完成一张就刷新整张窗口网格。
        schedule(policy.flushDelay) { [weak self] in
            guard let self, self.generation == token else { return }
            self.flushScheduled = false
            self.images = self.cache.mapValues(\.image)
        }
    }

    private func resetImages() {
        generation = UUID()
        enumerationRequest = nil
        activeCapture = nil
        ready = false
        available = nil
        unavailable.removeAll()
        requiredBytes.removeAll()
        cache.removeAll()
        cachedBytes = 0
        access = 0
        flushScheduled = false
        if !images.isEmpty { images = [:] }
    }

    func clear() {
        presentation = nil
        enabled = false
        shown = false
        visible.removeAll()
        selectedID = nil
        resetImages()
    }
}
