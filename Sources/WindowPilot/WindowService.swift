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
    var incomplete = false
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
        let coverage: CatalogCoverage
        let updatedAt: TimeInterval
        var freshness: CatalogFreshness
    }

    private struct ScanResult {
        let windows: [WindowEntry]
        let freshness: CatalogFreshness
        let coverage: CatalogCoverage
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
    private final class WindowObservation {
        let element: AXUIElement
        var registrations = NotificationRegistration()
        init(_ element: AXUIElement) { self.element = element }
    }
    private var observedWindows: [pid_t: [String: WindowObservation]] = [:]
    private var catalogEpoch = 0
    private var lifecycleEpoch = 0
    private var refreshing = false
    private var refreshAgain = false
    // 同时只有一个切换面板。冷启动时等请求范围真正扫到后再冻结本次选择列表。
    private var pendingDiscovery: ((Catalog) -> Void)?
    private var requestedPID: pid_t?
    private var discoveryID = UUID()
    private var invalidatedDuringScan = Set<String>()
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
        cancelDiscovery()
        invalidatedDuringScan.removeAll()
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
        let coverage = catalog?.coverage ?? CatalogCoverage()
        let nextPID = requestedPID ?? nextScanPID
        requestedPID = nil
        invalidatedDuringScan.removeAll()
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
            let result = Self.scan(appInfos, previous: previous, freshness: freshness, coverage: coverage, nextPID: nextPID, windowOffsets: offsets)
            DispatchQueue.main.async {
                guard let self, self.refreshRequest == request else { return }
                self.refreshing = false
                self.refreshRequest = nil
                if self.started, self.catalogEpoch == epoch {
                    self.nextScanPID = result.nextPID
                    self.windowOffsets = result.windowOffsets
                    let live = result.windows.filter { !self.invalidatedDuringScan.contains($0.id) }
                    self.catalog = Catalog(windows: live, coverage: result.coverage,
                                           updatedAt: ProcessInfo.processInfo.systemUptime, freshness: result.freshness)
                    self.syncWindowNotifications(live)
                    Diagnostics.shared.record("catalog", ["count": result.windows.count,
                        "durationMS": (ProcessInfo.processInfo.systemUptime - beganAt) * 1000,
                        "budgetExpired": result.budgetExpired])
                    if let catalog = self.catalog { self.pendingDiscovery?(catalog) }
                    if self.pendingDiscovery != nil && coverage != result.coverage { self.refreshAgain = true }
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
            var states = observedWindows[pid] ?? [:]
            for (id, state) in states where current[id].map({ CFEqual($0, state.element) }) != true {
                states.removeValue(forKey: id)
                observerQueue.async {
                    for name in notifications { AXObserverRemoveNotification(observer, state.element, name as CFString) }
                }
            }
            for (id, element) in current {
                let state = states[id] ?? WindowObservation(element)
                states[id] = state
                let missing = state.registrations.begin(notifications, now: ProcessInfo.processInfo.systemUptime)
                guard !missing.isEmpty else { continue }
                observerQueue.async { [weak self] in
                    guard let self else { return }
                    AXUIElementSetMessagingTimeout(element, 0.06)
                    let settled = missing.filter { name in
                        let code = AXObserverAddNotification(observer, element, name as CFString, Unmanaged.passUnretained(self).toOpaque())
                        return code == .success || code == .notificationAlreadyRegistered || code == .notificationUnsupported || code == .notImplemented
                    }
                    DispatchQueue.main.async {
                        guard self.observedWindows[pid]?[id] === state else { return }
                        state.registrations.finish(settled: settled, now: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
            observedWindows[pid] = states
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
        cancelDiscovery()
        let token = discoveryID
        let onlyPID = sameApp ? frontPID : nil
        let scope = onlyPID.map { Set([$0]) } ?? Set(runningApps().map(\.processIdentifier))
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
                                       catalogAgeMS: max(0, now - catalog.updatedAt) * 1000,
                                       incomplete: catalog.coverage.hasUnavailable(in: scope.intersection(live.keys))))
        }
        let resolve: (Catalog, Bool) -> Void = { [weak self] catalog, cached in
            guard let self else { return }
            guard let pid = frontPID, pid != getpid() else { deliver(catalog, cached, .unknown); return }
            let epoch = self.catalogEpoch
            self.shortcutFocusQueue.async { [weak self] in
                let focus = Self.frontWindow(pid: pid)
                DispatchQueue.main.async {
                    guard let self, self.started, self.catalogEpoch == epoch, self.discoveryID == token else { return }
                    deliver(self.catalog ?? catalog, cached, focus)
                }
            }
        }
        if let catalog, catalog.coverage.pending(in: scope).isEmpty {
            resolve(catalog, true)
        } else if started {
            requestedPID = onlyPID
            pendingDiscovery = { [weak self] snapshot in
                guard let self, self.discoveryID == token else { return }
                let remaining = snapshot.coverage.pending(in: scope.intersection(self.runningApps().map(\.processIdentifier)))
                guard remaining.isEmpty else {
                    if let onlyPID, remaining.contains(onlyPID) { self.requestedPID = onlyPID }
                    return // 已有轮转定时器；不为一直没响应的系统调用启动忙循环。
                }
                self.pendingDiscovery = nil
                self.requestedPID = nil
                resolve(snapshot, false)
            }
            refresh(followUp: true)
        } else {
            completion(WindowInventory(windows: [], focusedID: nil))
        }
    }

    func cancelDiscovery() {
        discoveryID = UUID()
        pendingDiscovery = nil
        requestedPID = nil
    }

    private static func scan(_ apps: [AppInfo], previous: [WindowEntry], freshness: CatalogFreshness,
                             coverage: CatalogCoverage, nextPID: pid_t?, windowOffsets: [pid_t: Int]) -> ScanResult {
        // 预算在每次 IPC 之间生效，不能中断系统内部调用；单次 AX 查询另设 60ms 超时。
        let deadline = ProcessInfo.processInfo.systemUptime + 0.75
        var freshness = freshness
        var coverage = coverage
        let livePIDs = Set(apps.map(\.pid))
        coverage.retain(livePIDs)
        var measuredTitles: [String: String] = [:]
        var offsets = windowOffsets.filter { livePIDs.contains($0.key) }
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
            guard result == .success, let windows = value as? [AXUIElement] else {
                if result == .attributeUnsupported || result == .noValue {
                    coverage.listed(app.pid, ids: [], checked: [])
                } else {
                    coverage.failed(app.pid)
                    entries += old.filter { freshness.isFresh($0.id, at: ProcessInfo.processInfo.systemUptime) }
                }
                continue
            }
            let identities = windows.map { elementID($0, pid: app.pid) }
            let listed = Set(identities)
            var checked = Set<String>()
            var unreadable = Set<String>()
            // 列表中仍有这个 AX 引用就能保留条目，但不代表已验证它的坐标。
            var retained = Dictionary(uniqueKeysWithValues: old.filter { listed.contains($0.id) }.map { ($0.id, $0) })
            for id in retained.keys { freshness.record(id, at: now) }
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
                checked.insert(id)
                if result == .cannotComplete { unreadable.insert(id); continue }
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
                measuredTitles[id] = title
            }
            coverage.listed(app.pid, ids: listed, checked: checked, failed: unreadable)
            entries += retained.values
        }
        let finishedAt = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { freshness.isFresh($0.id, at: finishedAt) }
        // 仅用本轮测得的几何认领截图。沿用条目保留 AX 切换能力，不保留旧编号。
        entries = Dictionary(grouping: entries, by: \.pid).flatMap { pid, windows -> [WindowEntry] in
            let matching = (candidates[pid] ?? []).map { WindowMatchCandidate(id: $0.id, bounds: $0.bounds, title: $0.title) }
            let associations = WindowMatcher.matchMeasured(windows.map { ($0.id, $0.bounds) }, titlesThisScan: measuredTitles, candidates: matching)
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
        return ScanResult(windows: entries, freshness: freshness, coverage: coverage, nextPID: resumePID,
                          windowOffsets: offsets, budgetExpired: budgetExpired)
    }

    func cancelActivation() { activator.cancel() }

    func activate(_ window: WindowEntry, completion: @escaping (WindowActivationResult) -> Void) {
        activator.activate(window) { [weak self] result in
            if result == .confirmed { self?.remember(window.id) }
            else if result != .superseded, let self {
                if result == .invalidTarget {
                    self.catalog?.windows.removeAll { $0.id == window.id }
                    self.recent.removeAll { $0 == window.id }
                    if self.refreshing { self.invalidatedDuringScan.insert(window.id) }
                }
                self.refresh(followUp: true)
            }
            completion(result)
        }
    }
}
