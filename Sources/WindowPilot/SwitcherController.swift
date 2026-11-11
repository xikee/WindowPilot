import AppKit
import Combine
import SwiftUI
import SwitchCore

final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowEntry] = []
    @Published var selectedID: String?
    @Published var query = ""
    @Published var loading = false
    @Published var isDemo = false
    @Published var sameApp = false
    @Published var presentationID = UUID()
    var choose: ((String) -> Void)?
    var cancel: (() -> Void)?
    var clearSearch: (() -> Void)?
}

private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SwitcherController {
    let model = SwitcherModel()
    let thumbnails = ThumbnailStore()
    let hotkeys = HotkeyMonitor()
    private let preferences: Preferences
    private let useDemoWindowsForShortcuts: Bool
    private let service = WindowService()
    private var session = SwitchSession()
    private var allWindows: [WindowEntry] = []
    private var panel: NSPanel?
    private var requestID = UUID()
    private var cancellables = Set<AnyCancellable>()
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var spaceMonitor: NSObjectProtocol?
    private var lastScreen = CGRect.zero
    var presentationView: NSView? { panel?.contentView }

    init(preferences: Preferences, useDemoWindowsForShortcuts: Bool = false) {
        self.preferences = preferences
        self.useDemoWindowsForShortcuts = useDemoWindowsForShortcuts
        hotkeys.onAction = { [weak self] in self?.handle($0) }
        model.choose = { [weak self] id in self?.session.select(id); self?.commit() }
        model.cancel = { [weak self] in self?.cancel() }
        model.clearSearch = { [weak self] in self?.updateSearch("") }
        preferences.$modifier.sink { [weak self] in self?.cancel(); self?.hotkeys.modifier = $0 }.store(in: &cancellables)
        preferences.$paused.dropFirst().sink { [weak self] paused in
            guard let self else { return }
            self.cancel()
            if paused { self.hotkeys.stop(); preferences.hotkeyAvailable = false }
            else { DispatchQueue.main.async { self.refreshPermissions() } }
        }.store(in: &cancellables)
        Publishers.CombineLatest3(preferences.$showThumbnails, preferences.$screenRecordingGranted, preferences.$compact)
            .map { $0 && $1 && !$2 }.removeDuplicates().sink { [weak self] enabled in
                guard let self, self.session.isActive, !self.model.isDemo else { return }
                self.thumbnails.setEnabled(enabled)
            }.store(in: &cancellables)
        // 界面验证直接调用按键处理器，不接收桌面上无关的鼠标、键盘或 Space 事件。
        guard !useDemoWindowsForShortcuts else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.dismissIfOutside() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissIfOutside()
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.hotkeys.handleLocal(event) == true ? nil : event
        }
        spaceMonitor = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in self?.cancel() }
    }

    func refreshPermissions() {
        let previous = (preferences.accessibilityGranted, preferences.screenRecordingGranted, preferences.hotkeyAvailable)
        preferences.refreshPermissions()
        if preferences.accessibilityGranted { service.start() }
        else {
            if session.isActive && !model.isDemo { cancel() }
            service.stop()
        }
        let hotkeyReady = preferences.accessibilityGranted && !preferences.paused && hotkeys.start()
        if !hotkeyReady && previous.2 { hotkeys.stop() }
        if preferences.hotkeyAvailable != hotkeyReady { preferences.hotkeyAvailable = hotkeyReady }
        if hotkeyReady && panel == nil { DispatchQueue.main.async { [weak self] in self?.preparePanel() } }
        let current = (preferences.accessibilityGranted, preferences.screenRecordingGranted, preferences.hotkeyAvailable)
        if previous != current {
            Diagnostics.shared.record("permissions", ["accessibility": current.0, "screenRecording": current.1, "hotkey": current.2])
        }
    }

    func showPinned(demo: Bool = false) {
        cancel()
        NSApp.activate(ignoringOtherApps: true)
        hotkeys.preparePinnedSession()
        begin(backward: false, sameApp: false, demo: demo, pinned: true)
    }

    private func handle(_ action: SwitchAction) {
        switch action {
        case let .begin(backward, sameApp): begin(backward: backward, sameApp: sameApp, demo: useDemoWindowsForShortcuts)
        case let .move(steps): session.move(steps); syncSelection()
        case .commit:
            Diagnostics.shared.record("shortcutConfirmed", ["waitingForInventory": session.isLoading])
            commit()
        case .cancel: cancel()
        case let .text(text): if model.query.count < 120 { updateSearch(model.query + text) }
        case .delete: updateSearch(String(model.query.dropLast()))
        case .clearSearch: updateSearch("")
        }
    }

    private func begin(backward: Bool, sameApp: Bool, demo: Bool = false, pinned: Bool = false) {
        Diagnostics.shared.record("begin", ["backward": backward, "sameApp": sameApp, "demo": demo, "pinned": pinned])
        requestID = UUID()
        let token = requestID
        session.begin(backward: backward)
        model.presentationID = token
        model.loading = true
        model.query = ""
        model.sameApp = sameApp
        model.isDemo = demo
        model.windows = []
        model.selectedID = nil
        thumbnails.begin(token, enabled: !demo && preferences.showThumbnails && preferences.screenRecordingGranted && !preferences.compact)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        lastScreen = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        DispatchQueue.main.asyncAfter(deadline: .now() + (pinned ? 0 : 0.04)) { [weak self] in
            guard let self, self.requestID == token, self.session.isActive, !self.session.commitWhenReady else { return }
            self.showPanel()
        }
        let complete: (WindowInventory) -> Void = { [weak self] inventory in
            guard let self, self.requestID == token, self.session.isActive else { return }
            self.allWindows = inventory.windows
            self.session.load(inventory.windows.map(\.id), currentID: pinned && !demo ? nil : inventory.focusedID)
            self.model.loading = false
            let focused = inventory.windows.first { $0.id == inventory.focusedID }
            Diagnostics.shared.record("inventory", ["count": inventory.windows.count, "cached": inventory.cached,
                                                      "focusSource": inventory.focusSource, "focusedWindow": focused?.windowID ?? 0])
            self.updateSearch(self.model.query)
            if self.session.commitWhenReady { self.commit(); return }
            if self.panel?.isVisible == true { self.resizePanel() }
        }
        if demo {
            complete(WindowInventory(windows: DemoWindows.entries, focusedID: DemoWindows.entries.first?.id))
        } else {
            let maxY = NSScreen.screens.first?.frame.maxY ?? 0
            let cgScreen = screen.map { CGRect(x: $0.frame.minX, y: maxY - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
            service.discover(includeMinimized: preferences.includeMinimized,
                             sameApp: sameApp, screen: preferences.currentScreenOnly ? cgScreen : nil,
                             resolveFrontWindow: !pinned, completion: complete)
        }
    }

    private func updateSearch(_ query: String) {
        model.query = query
        guard !session.isLoading else { return }
        model.windows = query.isEmpty ? allWindows : allWindows.filter { WindowSearch.matches(query: query, title: $0.title, app: $0.appName) }
        session.filter(to: model.windows.map(\.id))
        syncSelection()
    }

    private func syncSelection() {
        guard model.selectedID != session.selectedID else { return }
        model.selectedID = session.selectedID
        thumbnails.prioritize(session.selectedID)
        if let window = allWindows.first(where: { $0.id == session.selectedID }) {
            Diagnostics.shared.record("selection", ["pid": window.pid, "window": window.windowID ?? 0, "minimized": window.minimized])
        }
    }

    private func commit() {
        let id = session.release()
        if session.isLoading { return }
        let window = allWindows.first { $0.id == id }
        let isDemo = model.isDemo
        Diagnostics.shared.record("commit", ["loading": session.isLoading, "hasTarget": window != nil, "demo": isDemo])
        cancel()
        guard !isDemo, let window else { return }
        service.activate(window) { [weak self] success in
            Diagnostics.shared.record("activation", ["success": success, "pid": window.pid, "window": window.windowID ?? 0,
                                                      "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0])
            if !success { self?.preferences.statusMessage = "窗口已关闭或暂时无法切换，请重新打开切换器。" }
        }
    }

    func cancel() {
        if session.isActive { Diagnostics.shared.record("cancel") }
        session.cancel()
        hotkeys.endSession()
        requestID = UUID()
        if panel?.isVisible == true { panel?.orderOut(nil) }
        thumbnails.clear()
        allWindows = []
        model.windows = []
        model.selectedID = nil
        model.query = ""
        model.loading = false
    }

    func shutdown() {
        cancel()
        hotkeys.stop()
        service.stop()
    }

    private func dismissIfOutside() {
        if session.isActive, let panel, panel.isVisible, !panel.frame.contains(NSEvent.mouseLocation) { cancel() }
    }

    private func preparePanel() {
        if panel == nil {
            let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.title = "瞬切 · 窗口切换器"
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: SwitcherView(model: model, thumbnails: thumbnails, preferences: preferences))
            self.panel = panel
        }
    }

    private func showPanel() {
        preparePanel()
        resizePanel()
        panel?.makeKeyAndOrderFront(nil)
        thumbnails.panelDidShow()
        Diagnostics.shared.record("panel", ["visible": panel?.isVisible == true, "width": panel?.frame.width ?? 0, "height": panel?.frame.height ?? 0])
    }

    private func resizePanel() {
        guard let panel else { return }
        let rows = max(1, Int(ceil(Double(min(allWindows.count, 9)) / 3)))
        let width = min(920, lastScreen.width - 64)
        let columnWidth = (width - 48 - 24) / 3
        let rowHeight: CGFloat = preferences.compact ? 68 : columnWidth * 3 / 5 + 55
        let height = min(CGFloat(rows) * rowHeight + CGFloat(rows - 1) * 12 + 182, lastScreen.height - 64)
        let frame = CGRect(x: lastScreen.midX - width / 2, y: lastScreen.midY - height / 2, width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }
}
