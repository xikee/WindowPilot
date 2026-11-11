import AppKit
import ApplicationServices
import SwitchCore

struct WindowEntry: Identifiable {
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String
    let title: String
    let bounds: CGRect
    let minimized: Bool
    var hidden: Bool
    let element: AXUIElement?
    var icon: NSImage? = nil
    var demoStyle: Int? = nil
}

struct WindowInventory {
    let windows: [WindowEntry]
    let focusedID: String?
    var cached = false
    var focusSource = "none"
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

private func elementID(_ element: AXUIElement, pid: pid_t) -> String { "\(pid):\(CFHash(element))" }

private func frame(position: Any, size: Any) -> CGRect? {
    let position = position as CFTypeRef
    let size = size as CFTypeRef
    guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
          AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
}

final class WindowService {
    private struct AppInfo {
        let pid: pid_t
        let name: String
        let hidden: Bool
        let icon: NSImage?
    }

    private struct Catalog {
        let windows: [WindowEntry]
        let pids: Set<pid_t>
    }

    private struct CGWindow {
        let id: CGWindowID
        let bounds: CGRect
        let title: String?
        let rank: Int
    }

    private enum FrontWindow {
        case accessibility(String)
        case windowServer(CGWindowID)
        case unknown
    }

    // 状态归主线程所有。目录刷新、焦点查询与切换分别排队，避免慢应用阻塞选中的窗口。
    private let catalogQueue = DispatchQueue(label: "app.windowpilot.catalog", qos: .utility)
    private let observerQueue = DispatchQueue(label: "app.windowpilot.observers", qos: .utility)
    private let focusQueue = DispatchQueue(label: "app.windowpilot.focus", qos: .userInitiated)
    private let shortcutFocusQueue = DispatchQueue(label: "app.windowpilot.shortcut-focus", qos: .userInitiated, attributes: .concurrent)
    private let activationQueue = DispatchQueue(label: "app.windowpilot.activation", qos: .userInteractive)
    private var catalog: Catalog?
    private var catalogEpoch = 0
    private var lifecycleEpoch = 0
    private var refreshing = false
    private var refreshAgain = false
    private var waiters: [(Catalog) -> Void] = []
    private var focusPending: pid_t?
    private var readingFocus = false
    private var focusRevision = 0
    private var recent: [String] = []
    private var apps: [pid_t: AppInfo] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var observerRequests = Set<pid_t>()
    private var workspaceTokens: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var started = false

    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        lifecycleEpoch &+= 1
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.noteFocus()
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh(followUp: true)
            })
        }
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.catalogEpoch &+= 1
            self.catalog = nil
            self.noteFocus()
            self.refresh(followUp: true)
        })
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        noteFocus()
        refresh(followUp: true)
    }

    func stop() {
        guard started else { return }
        started = false
        lifecycleEpoch &+= 1
        catalogEpoch &+= 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
        observerRequests.removeAll()
        catalog = nil
        waiters.removeAll()
        focusPending = nil
        recent.removeAll()
        apps.removeAll()
    }

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
    }

    private func refresh(followUp: Bool = false) {
        guard started else { return }
        if refreshing { refreshAgain = refreshAgain || followUp; return }
        refreshing = true
        refreshAgain = false
        let epoch = catalogEpoch
        let previous = catalog?.windows ?? []
        let currentApps = runningApps()
        let oldApps = apps
        apps = Dictionary(uniqueKeysWithValues: currentApps.map { app in
            let pid = app.processIdentifier
            let info = AppInfo(pid: pid, name: oldApps[pid]?.name ?? app.localizedName ?? "应用",
                               hidden: app.isHidden, icon: oldApps[pid]?.icon ?? app.icon)
            return (pid, info)
        })
        let appInfos = currentApps.compactMap { apps[$0.processIdentifier] }
        let pids = Set(apps.keys)
        syncObservers(pids)
        catalogQueue.async { [weak self] in
            let result = Self.scan(appInfos, previous: previous)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if self.started, self.catalogEpoch == epoch {
                    self.catalog = Catalog(windows: result, pids: pids)
                    let callbacks = self.waiters
                    self.waiters.removeAll()
                    if let catalog = self.catalog { callbacks.forEach { $0(catalog) } }
                }
                if self.refreshAgain { self.refresh() }
            }
        }
    }

    private func syncObservers(_ pids: Set<pid_t>) {
        for pid in observerRequests.subtracting(pids) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        observerRequests.formIntersection(pids)
        let newPIDs = pids.subtracting(observerRequests)
        observerRequests.formUnion(newPIDs)
        let epoch = lifecycleEpoch
        for pid in newPIDs {
            observerQueue.async { [weak self] in
                guard let self else { return }
                var observer: AXObserver?
                let result = AXObserverCreate(pid, { _, _, notification, context in
                    guard let context else { return }
                    let service = Unmanaged<WindowService>.fromOpaque(context).takeUnretainedValue()
                    if notification as String == kAXFocusedWindowChangedNotification { service.noteFocus() }
                    else { service.refresh(followUp: true) }
                }, &observer)
                guard result == .success, let observer else { return }
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.10)
                for notification in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    AXObserverAddNotification(observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lifecycleEpoch == epoch, self.observerRequests.contains(pid) else { return }
                    self.observers[pid] = observer
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
            }
        }
    }

    private func noteFocus() {
        guard started, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        focusRevision &+= 1
        focusPending = pid
        readFocus()
    }

    private func readFocus() {
        guard !readingFocus, let pid = focusPending else { return }
        readingFocus = true
        focusPending = nil
        let revision = focusRevision
        let epoch = lifecycleEpoch
        focusQueue.async { [weak self] in
            let id = Self.focusedWindowID(pid: pid, timeout: 0.10)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingFocus = false
                if self.lifecycleEpoch == epoch, self.focusRevision == revision,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let id {
                    self.remember(id)
                    if self.catalog?.windows.contains(where: { $0.id == id }) == false { self.refresh(followUp: true) }
                }
                self.readFocus()
            }
        }
    }

    private func remember(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 300 { recent.removeLast() }
    }

    private static func focusedWindowID(pid: pid_t, timeout: Float) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return elementID(unsafeBitCast(value, to: AXUIElement.self), pid: pid)
    }

    private static func frontWindow(pid: pid_t) -> FrontWindow {
        if let id = focusedWindowID(pid: pid, timeout: 0.06) { return .accessibility(id) }
        // 前台应用暂时不回答时，用窗口服务器的实时顺序，避免把旧焦点当成当前窗口。
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in descriptions where info[kCGWindowOwnerPID as String] as? pid_t == pid && info[kCGWindowLayer as String] as? Int == 0 {
            guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary), bounds.width > 80, bounds.height > 50,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return .windowServer(id)
        }
        return .unknown
    }

    func discover(includeMinimized: Bool, sameApp: Bool, screen: CGRect?, resolveFrontWindow: Bool,
                  completion: @escaping (WindowInventory) -> Void) {
        let frontPID = resolveFrontWindow ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        let onlyPID = sameApp ? frontPID : nil
        let deliver: (Catalog, Bool, FrontWindow) -> Void = { [weak self] catalog, cached, focus in
            guard let self else { return }
            let live = Dictionary(uniqueKeysWithValues: self.runningApps().map { ($0.processIdentifier, $0.isHidden) })
            let windows = catalog.windows.compactMap { window -> WindowEntry? in
                guard let hidden = live[window.pid], onlyPID == nil || window.pid == onlyPID,
                      includeMinimized || !window.minimized, screen?.intersects(window.bounds) != false else { return nil }
                var window = window
                window.hidden = hidden
                return window
            }
            let current: String?
            let source: String
            switch focus {
            case let .accessibility(id):
                current = id
                source = "accessibility"
            case let .windowServer(id):
                current = windows.first(where: { $0.pid == frontPID && $0.windowID == id })?.id
                source = "windowServer"
            case .unknown:
                current = nil
                source = "none"
            }
            let ordered = WindowOrder.byRecency(windows, id: \.id, focusedID: current, recent: self.recent)
            completion(WindowInventory(windows: ordered, focusedID: current, cached: cached, focusSource: source))
        }
        let resolve: (Catalog, Bool) -> Void = { [weak self] catalog, cached in
            guard let self else { return }
            guard let pid = frontPID, pid != getpid() else { deliver(catalog, cached, .unknown); return }
            let epoch = self.catalogEpoch
            self.shortcutFocusQueue.async { [weak self] in
                let focus = Self.frontWindow(pid: pid)
                DispatchQueue.main.async {
                    guard let self, self.started, self.catalogEpoch == epoch else { return }
                    deliver(self.catalog ?? catalog, cached, focus)
                }
            }
        }
        if let catalog, onlyPID.map(catalog.pids.contains) != false {
            resolve(catalog, true)
        } else if started {
            waiters.append { resolve($0, false) }
            refresh()
        } else {
            completion(WindowInventory(windows: [], focusedID: nil))
        }
    }

    private static func scan(_ apps: [AppInfo], previous: [WindowEntry]) -> [WindowEntry] {
        let descriptions = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates: [pid_t: [CGWindow]] = [:]
        for (rank, info) in descriptions.enumerated() {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { continue }
            candidates[pid, default: []].append(CGWindow(id: id, bounds: bounds, title: info[kCGWindowName as String] as? String, rank: rank))
        }
        let previousByPID = Dictionary(grouping: previous, by: \.pid)
        var entries: [(WindowEntry, Int)] = []
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXTitleAttribute] as CFArray
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.12)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
            let matching = candidates[app.pid] ?? []
            if result == .cannotComplete {
                entries += (previousByPID[app.pid] ?? []).map { entry in (entry, matching.first(where: { $0.id == entry.windowID })?.rank ?? Int.max) }
                continue
            }
            guard result == .success, let windows = value as? [AXUIElement] else { continue }
            var matched = Set<CGWindowID>()
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.12)
                var values: CFArray?
                let result = AXUIElementCopyMultipleAttributeValues(window, names, [], &values)
                let id = elementID(window, pid: app.pid)
                if result == .cannotComplete, let old = previousByPID[app.pid]?.first(where: { $0.id == id }) {
                    entries.append((old, matching.first(where: { $0.id == old.windowID })?.rank ?? Int.max))
                    if let oldID = old.windowID { matched.insert(oldID) }
                    continue
                }
                guard result == .success, let attributes = values as? [Any], attributes.count == 5,
                      let bounds = frame(position: attributes[0], size: attributes[1]), bounds.width > 80, bounds.height > 50 else { continue }
                let subrole = attributes[2] as? String ?? ""
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole || subrole.isEmpty else { continue }
                let minimized = attributes[3] as? Bool ?? false
                let title = attributes[4] as? String ?? ""
                let match = matching.lazy.filter { !matched.contains($0.id) }.compactMap { candidate -> (CGWindow, CGFloat)? in
                    let rect = candidate.bounds
                    let delta = abs(rect.minX - bounds.minX) + abs(rect.minY - bounds.minY) + abs(rect.width - bounds.width) + abs(rect.height - bounds.height)
                    let sameTitle = !title.isEmpty && candidate.title == title
                    return delta < 8 || sameTitle ? (candidate, delta + (sameTitle ? 0 : 100)) : nil
                }.min { $0.1 < $1.1 }?.0
                if let match { matched.insert(match.id) }
                let entry = WindowEntry(id: id, windowID: match?.id, pid: app.pid, appName: app.name,
                                        title: title.isEmpty ? app.name : title, bounds: bounds, minimized: minimized,
                                        hidden: app.hidden, element: window, icon: app.icon)
                entries.append((entry, match?.rank ?? Int.max))
            }
        }
        return entries.sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1 }.map(\.0)
    }

    func activate(_ window: WindowEntry, completion: @escaping (Bool) -> Void) {
        guard let element = window.element, let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
            completion(false)
            return
        }
        if app.isHidden { app.unhide() }
        if !app.isActive { app.activate(options: []) }
        activationQueue.async { [weak self] in
            // 只核对目标窗口的实时最小化状态；后台快照可能刚好早于最小化操作。
            if attribute(element, kAXMinimizedAttribute) as? Bool ?? window.minimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            let success: Bool
            if result == .success {
                success = true
            } else {
                let application = AXUIElementCreateApplication(window.pid)
                AXUIElementSetMessagingTimeout(application, 0.12)
                success = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, element) == .success
            }
            DispatchQueue.main.async {
                if success {
                    self?.remember(window.id)
                } else if let self {
                    if let catalog = self.catalog {
                        self.catalog = Catalog(windows: catalog.windows.filter { $0.id != window.id }, pids: catalog.pids)
                    }
                    self.refresh(followUp: true)
                }
                completion(success)
            }
        }
    }
}
