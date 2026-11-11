import AppKit
import ScreenCaptureKit

final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "app.windowpilot.thumbnails", qos: .utility)
    private var generation = UUID()
    private var presentation: UUID?
    private var activeCapture: UUID?
    private var visible: [WindowEntry] = []
    private var attempted = Set<String>()
    private var pendingImages: [String: NSImage] = [:]
    private var flushScheduled = false
    private var selectedID: String?
    private var available: [CGWindowID: SCWindow]?
    private var loadingContent = false
    private var enabled = false
    private var shown = false
    private var ready = false

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
        pump()
    }

    func remove(_ id: String, presentation: UUID) {
        guard self.presentation == presentation else { return }
        visible.removeAll { $0.id == id }
    }

    func prioritize(_ id: String?) {
        selectedID = id
        pump()
    }

    private func schedulePreviews() {
        guard enabled, shown, !ready else { return }
        let token = generation
        // 快速切换通常已经结束；只有留在屏幕上的面板才需要截图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self, self.generation == token, self.enabled, self.shown else { return }
            self.ready = true
            self.pump()
        }
    }

    private func pump() {
        guard ready, activeCapture == nil else { return }
        let candidates = visible.filter { !attempted.contains($0.id) }
        guard let entry = candidates.first(where: { $0.id == selectedID }) ?? candidates.first,
              let id = entry.windowID else { return }
        let token = generation
        if #available(macOS 14.0, *) {
            guard let available else {
                if !loadingContent {
                    loadingContent = true
                    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            self.loadingContent = false
                            self.available = (content?.windows ?? []).reduce(into: [:]) { $0[$1.windowID] = $1 }
                            self.pump()
                        }
                    }
                }
                return
            }
            attempted.insert(entry.id)
            guard let window = available[id] else { pump(); return }
            let finish = beginCapture(entry, token: token)
            let config = SCStreamConfiguration()
            config.width = 560
            config.height = max(1, min(1120, Int(560 * window.frame.height / max(1, window.frame.width))))
            config.showsCursor = false
            config.scalesToFit = true
            config.preservesAspectRatio = true
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) { image, _ in
                DispatchQueue.main.async { finish(image) }
            }
        } else {
            attempted.insert(entry.id)
            let finish = beginCapture(entry, token: token)
            queue.async {
                let image = Self.captureLegacy(id)
                DispatchQueue.main.async { finish(image) }
            }
        }
    }

    private func beginCapture(_ entry: WindowEntry, token: UUID) -> (CGImage?) -> Void {
        let capture = UUID()
        activeCapture = capture
        let finish: (CGImage?) -> Void = { [weak self] image in
            guard let self, self.generation == token, self.activeCapture == capture else { return }
            self.activeCapture = nil
            if let image {
                self.pendingImages[entry.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.scheduleFlush(token)
                Diagnostics.shared.record("thumbnail", ["window": entry.windowID ?? 0, "width": image.width, "height": image.height])
            } else {
                Diagnostics.shared.record("thumbnailUnavailable", ["window": entry.windowID ?? 0])
            }
            self.pump()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
        return finish
    }

    private func scheduleFlush(_ token: UUID) {
        guard !flushScheduled else { return }
        flushScheduled = true
        // 合并相邻截图，避免每完成一张就刷新整张窗口网格。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, self.generation == token else { return }
            self.flushScheduled = false
            self.images.merge(self.pendingImages, uniquingKeysWith: { _, new in new })
            self.pendingImages.removeAll()
        }
    }

    @available(macOS, introduced: 13.0, obsoleted: 14.0)
    private static func captureLegacy(_ id: CGWindowID) -> CGImage? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        let width = min(560, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func resetImages() {
        generation = UUID()
        activeCapture = nil
        ready = false
        available = nil
        loadingContent = false
        attempted.removeAll()
        pendingImages.removeAll()
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
