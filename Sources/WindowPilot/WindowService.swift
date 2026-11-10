import AppKit
import ApplicationServices
import ScreenCaptureKit

struct WindowEntry: Identifiable {
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let minimized: Bool
    let hidden: Bool
    let element: AXUIElement?
    var demoStyle: Int? = nil
}

struct WindowInventory {
    let windows: [WindowEntry]
    let focusedID: String?
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func elementID(_ element: AXUIElement, pid: pid_t) -> String { "\(pid):\(CFHash(element))" }

private func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

final class WindowService {
    private let queue = DispatchQueue(label: "app.windowpilot.accessibility", qos: .userInitiated)
    private var observers: [pid_t: AXObserver] = [:]
    private var recent: [String] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        updateObservers()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateObservers()
                self?.noteFocus()
            })
        }
        noteFocus()
    }

    private func updateObservers() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let livePIDs = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !livePIDs.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        for app in apps where observers[app.processIdentifier] == nil {
            var observer: AXObserver?
            let result = AXObserverCreate(app.processIdentifier, { _, _, _, context in
                guard let context else { return }
                Unmanaged<WindowService>.fromOpaque(context).takeUnretainedValue().noteFocus()
            }, &observer)
            guard result == .success, let observer else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.15)
            AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            observers[app.processIdentifier] = observer
        }
    }

    private func noteFocus() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        queue.async { [weak self] in
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            let id = elementID(unsafeBitCast(value, to: AXUIElement.self), pid: pid)
            self?.markRecent(id)
        }
    }

    private func markRecent(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 300 { recent = Array(recent.prefix(300)) }
    }

    func discover(includeMinimized: Bool, onlyPID: pid_t?, screen: CGRect?, completion: @escaping (WindowInventory) -> Void) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "应用", hidden: $0.isHidden) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            let descriptions = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let cgWindows = descriptions.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            var entries: [(window: WindowEntry, rank: Int)] = []
            var focusedID: String?
            for app in apps where onlyPID == nil || onlyPID == app.pid {
                let element = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(element, 0.15)
                if app.pid == frontPID, let focus = attribute(element, kAXFocusedWindowAttribute), CFGetTypeID(focus) == AXUIElementGetTypeID() {
                    focusedID = elementID(unsafeBitCast(focus, to: AXUIElement.self), pid: app.pid)
                }
                guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                var matchedIDs = Set<CGWindowID>()
                for window in windows {
                    guard let bounds = frame(of: window), bounds.width > 80, bounds.height > 50 else { continue }
                    let subrole = attribute(window, kAXSubroleAttribute) as? String ?? ""
                    guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole || subrole.isEmpty else { continue }
                    let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
                    guard includeMinimized || !minimized else { continue }
                    if let screen, !screen.intersects(bounds) { continue }
                    let title = attribute(window, kAXTitleAttribute) as? String ?? ""
                    let match = cgWindows.enumerated().compactMap { index, info -> (index: Int, id: CGWindowID, score: CGFloat)? in
                        guard info[kCGWindowOwnerPID as String] as? pid_t == app.pid,
                              let number = info[kCGWindowNumber as String] as? UInt32, !matchedIDs.contains(number),
                              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                              let rect = CGRect(dictionaryRepresentation: dictionary) else { return nil }
                        let delta = abs(rect.minX - bounds.minX) + abs(rect.minY - bounds.minY) + abs(rect.width - bounds.width) + abs(rect.height - bounds.height)
                        let sameTitle = !title.isEmpty && info[kCGWindowName as String] as? String == title
                        guard delta < 8 || sameTitle else { return nil }
                        return (index, number, delta + (sameTitle ? 0 : 100))
                    }.min { $0.score < $1.score }
                    if let match { matchedIDs.insert(match.id) }
                    let entry = WindowEntry(id: elementID(window, pid: app.pid), windowID: match?.id, pid: app.pid, appName: app.name,
                                            title: title.isEmpty ? app.name : title, bounds: bounds, minimized: minimized, hidden: app.hidden, element: window)
                    entries.append((entry, match?.index ?? 10_000))
                }
            }
            if let focusedID { self.markRecent(focusedID) }
            let ranks = Dictionary(uniqueKeysWithValues: self.recent.enumerated().map { ($0.element, $0.offset) })
            entries.sort {
                let lhs = ranks[$0.window.id] ?? 1000 + $0.rank
                let rhs = ranks[$1.window.id] ?? 1000 + $1.rank
                if lhs != rhs { return lhs < rhs }
                return $0.window.id < $1.window.id
            }
            let inventory = WindowInventory(windows: entries.map(\.window), focusedID: focusedID)
            DispatchQueue.main.async { completion(inventory) }
        }
    }

    func activate(_ window: WindowEntry, completion: @escaping (Bool) -> Void) {
        guard let element = window.element else { completion(false); return }
        // 在主线程激活应用，在串行队列调用可能阻塞的辅助功能 API。
        let app = NSRunningApplication(processIdentifier: window.pid)
        app?.unhide()
        app?.activate(options: [])
        queue.async { [weak self] in
            if window.minimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(window.pid), kAXFocusedWindowAttribute as CFString, element)
            if result == .success { self?.markRecent(window.id) }
            DispatchQueue.main.async { completion(result == .success) }
        }
    }
}

final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private let queue = DispatchQueue(label: "app.windowpilot.thumbnails", qos: .utility)
    private var generation = UUID()

    func load(_ windows: [WindowEntry], allowed: Bool) {
        let token = UUID()
        generation = token
        images = [:]
        guard allowed else { return }
        if #available(macOS 14.0, *) {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, let content else { return }
                    let available = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
                    self.captureModern(windows, index: 0, available: available, token: token)
                }
            }
        } else {
            loadLegacy(windows, token: token)
        }
    }

    @available(macOS 14.0, *)
    private func captureModern(_ windows: [WindowEntry], index: Int, available: [CGWindowID: SCWindow], token: UUID) {
        guard generation == token, index < windows.count else { return }
        let entry = windows[index]
        guard let id = entry.windowID, let window = available[id] else {
            captureModern(windows, index: index + 1, available: available, token: token)
            return
        }
        let config = SCStreamConfiguration()
        config.width = 640
        config.height = max(1, min(1280, Int(640 * window.frame.height / max(1, window.frame.width))))
        config.showsCursor = false
        config.scalesToFit = true
        config.preservesAspectRatio = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if let image { self.images[entry.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
                self.captureModern(windows, index: index + 1, available: available, token: token)
            }
        }
    }

    @available(macOS, introduced: 13.0, obsoleted: 14.0)
    private func loadLegacy(_ windows: [WindowEntry], token: UUID) {
        queue.async { [weak self] in
            for window in windows {
                let valid = DispatchQueue.main.sync { self?.generation == token }
                guard valid else { return }
                guard let id = window.windowID,
                      let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else { continue }
                // 缓存缩略尺寸，避免为每个窗口保留完整分辨率的图像。
                let width = min(640, image.width)
                let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let thumbnail = context.makeImage() else { continue }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.images[window.id] = NSImage(cgImage: thumbnail, size: NSSize(width: width, height: height))
                }
            }
        }
    }

    func clear() { generation = UUID(); images = [:] }
}
