import AppKit
import ApplicationServices
import SwitchCore

struct WindowEntry: Identifiable {
    let id: String
    var windowID: CGWindowID?
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
    var catalogAgeMS: Double = 0
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
        var windows: [WindowEntry]
        let pids: Set<pid_t>
        let updatedAt: TimeInterval
        var freshness: CatalogFreshness
    }

    private struct ScanResult {
        let windows: [WindowEntry]
        let freshness: CatalogFreshness
        let nextPID: pid_t?
        let windowOffsets: [pid_t: Int]
        let budgetExpired: Bool
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
    private let activator = WindowActivator()
    private var catalog: Catalog?
    private var refreshRequest: UUID?
    private var nextScanPID: pid_t?
    private var windowOffsets: [pid_t: Int] = [:]
    private var observerRetryAfter: [pid_t: TimeInterval] = [:]
    private var observedWindows: [pid_t: [String: AXUIElement]] = [:]
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
    private var eventRefresh: DispatchWorkItem?
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
        eventRefresh?.cancel()
        eventRefresh = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
        observerRequests.removeAll()
        observerRetryAfter.removeAll()
        observedWindows.removeAll()
        refreshRequest = nil
        refreshing = false
        refreshAgain = false
        nextScanPID = nil
        windowOffsets.removeAll()
        activator.cancel()
        catalog = nil
        waiters.removeAll()
        readingFocus = false
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
        let freshness = catalog?.freshness ?? CatalogFreshness()
        let nextPID = nextScanPID
        let offsets = windowOffsets
        let request = UUID()
        refreshRequest = request
        let beganAt = ProcessInfo.processInfo.systemUptime
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
            let result = Self.scan(appInfos, previous: previous, freshness: freshness, nextPID: nextPID, windowOffsets: offsets)
            DispatchQueue.main.async {
                guard let self, self.refreshRequest == request else { return }
                self.refreshing = false
                self.refreshRequest = nil
                if self.started, self.catalogEpoch == epoch {
                    self.nextScanPID = result.nextPID
                    self.windowOffsets = result.windowOffsets
                    self.catalog = Catalog(windows: result.windows, pids: pids,
                                           updatedAt: ProcessInfo.processInfo.systemUptime, freshness: result.freshness)
                    self.syncWindowNotifications(result.windows)
                    Diagnostics.shared.record("catalog", ["count": result.windows.count,
                        "durationMS": (ProcessInfo.processInfo.systemUptime - beganAt) * 1000,
                        "budgetExpired": result.budgetExpired])
                    let callbacks = self.waiters
                    self.waiters.removeAll()
                    if let catalog = self.catalog { callbacks.forEach { $0(catalog) } }
                }
                if self.refreshAgain { self.refresh() }
            }
        }
    }

    private func scheduleEventRefresh() {
        guard started else { return }
        eventRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.eventRefresh = nil
            self?.refresh(followUp: true)
        }
        eventRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func syncObservers(_ pids: Set<pid_t>) {
        for pid in Set(observers.keys).subtracting(pids) {
            if let observer = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observedWindows.removeValue(forKey: pid)
        }
        observerRequests.formIntersection(pids)
        observerRetryAfter = observerRetryAfter.filter { pids.contains($0.key) }
        let now = ProcessInfo.processInfo.systemUptime
        let newPIDs = pids.subtracting(observers.keys).subtracting(observerRequests).filter { observerRetryAfter[$0, default: 0] <= now }
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
                    else { service.scheduleEventRefresh() }
                }, &observer)
                var registered = 0
                if result == .success, let observer {
                    let element = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(element, 0.06)
                    for notification in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
                        let code = AXObserverAddNotification(observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                        if code == .success || code == .notificationAlreadyRegistered { registered += 1 }
                    }
                }
                let registeredCount = registered
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.started, self.lifecycleEpoch == epoch, self.observerRequests.remove(pid) != nil else { return }
                    guard result == .success, let observer, registeredCount > 0 else {
                        self.observerRetryAfter[pid] = ProcessInfo.processInfo.systemUptime + 5
                        Diagnostics.shared.record("observerUnavailable", ["pid": pid, "code": result.rawValue, "registered": registeredCount])
                        return
                    }
                    self.observerRetryAfter.removeValue(forKey: pid)
                    self.observers[pid] = observer
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                    self.syncWindowNotifications(self.catalog?.windows ?? [])
                }
            }
        }
    }

    private func syncWindowNotifications(_ windows: [WindowEntry]) {
        let grouped = Dictionary(grouping: windows, by: \.pid)
        let notifications = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXMovedNotification,
                             kAXResizedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
        for (pid, observer) in observers {
            let current = Dictionary(uniqueKeysWithValues: (grouped[pid] ?? []).compactMap { window in
                window.element.map { (window.id, $0) }
            })
            let previous = observedWindows[pid] ?? [:]
            let removed = previous.filter { current[$0.key] == nil }
            let added = current.filter { previous[$0.key] == nil }
            guard !removed.isEmpty || !added.isEmpty else { continue }
            observedWindows[pid] = current
            observerQueue.async { [weak self] in
                guard let self else { return }
                for element in removed.values {
                    for notification in notifications { AXObserverRemoveNotification(observer, element, notification as CFString) }
                }
                for element in added.values {
                    AXUIElementSetMessagingTimeout(element, 0.06)
                    for notification in notifications {
                        AXObserverAddNotification(observer, element, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                    }
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
                guard let self, self.lifecycleEpoch == epoch else { return }
                self.readingFocus = false
                if self.focusRevision == revision,
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
            let now = ProcessInfo.processInfo.systemUptime
            let windows = catalog.windows.compactMap { window -> WindowEntry? in
                guard catalog.freshness.isFresh(window.id, at: now),
                      let hidden = live[window.pid], onlyPID == nil || window.pid == onlyPID,
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
            completion(WindowInventory(windows: ordered, focusedID: current, cached: cached, focusSource: source,
                                       catalogAgeMS: max(0, now - catalog.updatedAt) * 1000))
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

    private static func scan(_ apps: [AppInfo], previous: [WindowEntry], freshness: CatalogFreshness,
                             nextPID: pid_t?, windowOffsets: [pid_t: Int]) -> ScanResult {
        // 预算在每次 IPC 之间生效，不能中断系统内部调用；单次 AX 查询另设 60ms 超时。
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var freshness = freshness
        var offsets = windowOffsets.filter { pid, _ in apps.contains { $0.pid == pid } }
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
        var entries: [WindowEntry] = []
        let names = [kAXPositionAttribute, kAXSizeAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXTitleAttribute] as CFArray
        let start = apps.firstIndex { $0.pid == nextPID } ?? 0
        let ordered = Array(apps.dropFirst(start)) + Array(apps.prefix(start))
        var resumePID = ordered.first?.pid
        var budgetExpired = false
        for (index, app) in ordered.enumerated() {
            let now = ProcessInfo.processInfo.systemUptime
            let old = previousByPID[app.pid] ?? []
            if now >= deadline {
                entries += old.filter { freshness.isFresh($0.id, at: now) }
                budgetExpired = true
                continue
            }
            resumePID = ordered[(index + 1) % ordered.count].pid
            let appDeadline = min(deadline, now + 0.25)
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, Float(min(0.06, max(0.001, appDeadline - now))))
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
            if result == .cannotComplete {
                entries += old.filter { freshness.isFresh($0.id, at: ProcessInfo.processInfo.systemUptime) }
                continue
            }
            guard result == .success, let windows = value as? [AXUIElement] else { continue }
            let identities = windows.map { elementID($0, pid: app.pid) }
            var retained = Dictionary(uniqueKeysWithValues: old.filter { identities.contains($0.id) && freshness.isFresh($0.id, at: now) }.map { ($0.id, $0) })
            let offset = windows.isEmpty ? 0 : offsets[app.pid, default: 0] % windows.count
            for step in 0..<windows.count {
                let position = (offset + step) % windows.count
                let currentTime = ProcessInfo.processInfo.systemUptime
                guard currentTime < appDeadline else { budgetExpired = true; break }
                offsets[app.pid] = (position + 1) % windows.count
                let window = windows[position]
                let id = identities[position]
                AXUIElementSetMessagingTimeout(window, Float(min(0.06, max(0.001, appDeadline - currentTime))))
                var values: CFArray?
                let result = AXUIElementCopyMultipleAttributeValues(window, names, [], &values)
                if result == .cannotComplete { continue }
                retained.removeValue(forKey: id)
                guard result == .success, let attributes = values as? [Any], attributes.count == 5,
                      let bounds = frame(position: attributes[0], size: attributes[1]), bounds.width > 80, bounds.height > 50 else { continue }
                let subrole = attributes[2] as? String ?? ""
                guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole || subrole.isEmpty else { continue }
                let title = attributes[4] as? String ?? ""
                retained[id] = WindowEntry(id: id, windowID: nil, pid: app.pid, appName: app.name,
                                          title: title.isEmpty ? app.name : title, bounds: bounds,
                                          minimized: attributes[3] as? Bool ?? false, hidden: app.hidden, element: window, icon: app.icon)
                freshness.record(id, at: ProcessInfo.processInfo.systemUptime)
            }
            entries += retained.values
        }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { freshness.isFresh($0.id, at: finishedAt) }
        // 超时沿用的条目也重新核对本轮 CG 候选，不能继续持有可能已被复用的截图编号。
        entries = Dictionary(grouping: entries, by: \.pid).flatMap { pid, windows -> [WindowEntry] in
            let matching = (candidates[pid] ?? []).map { WindowMatchCandidate(id: $0.id, bounds: $0.bounds, title: $0.title) }
            let associations = WindowMatcher.matchAll(windows.map { ($0.id, $0.bounds, $0.title) }, candidates: matching)
            return windows.map { window in
                var window = window
                window.windowID = associations[window.id]
                return window
            }
        }
        freshness.retain(Set(entries.map(\.id)))
        let ranks = Dictionary(uniqueKeysWithValues: candidates.values.flatMap { $0 }.map { ($0.id, $0.rank) })
        entries.sort { lhs, rhs in
            let a = lhs.windowID.flatMap { ranks[$0] } ?? Int.max
            let b = rhs.windowID.flatMap { ranks[$0] } ?? Int.max
            return a == b ? lhs.id < rhs.id : a < b
        }
        return ScanResult(windows: entries, freshness: freshness, nextPID: resumePID,
                          windowOffsets: offsets, budgetExpired: budgetExpired)
    }

    func cancelActivation() { activator.cancel() }

    func activate(_ window: WindowEntry, completion: @escaping (WindowActivationResult) -> Void) {
        activator.activate(window) { [weak self] result in
            if result == .confirmed { self?.remember(window.id) }
            else if result != .superseded { self?.refresh(followUp: true) }
            completion(result)
        }
    }
}
