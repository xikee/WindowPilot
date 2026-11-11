import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let preferences = Preferences()
    private lazy var switcher = SwitcherController(preferences: preferences)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private var isRendering = false
    private var verification: UIVerification?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.shared.record("launch")
        setupApplicationMenu()
        if let index = CommandLine.arguments.firstIndex(of: "--verify-ui"), CommandLine.arguments.indices.contains(index + 1) {
            verification = UIVerification(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            verification?.start()
            return
        }
        isRendering = CommandLine.arguments.contains("--render-preview")
        setupMenu()
        if !isRendering {
            switcher.refreshPermissions()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.switcher.refreshPermissions() }
        }
        showSettings()
        if isRendering { renderPreview() }
        else if CommandLine.arguments.contains("--demo") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.switcher.showPinned(demo: true) } }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle.angled", accessibilityDescription: "瞬切 WindowPilot")
        let menu = NSMenu()
        let title = NSMenuItem(title: "瞬切 WindowPilot", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        addMenuItem("切换窗口…", action: #selector(showWindows), to: menu)
        addMenuItem("体验切换器…", action: #selector(showDemo), to: menu)
        menu.addItem(.separator())
        addMenuItem("设置…", action: #selector(showSettings), to: menu, key: ",")
        addMenuItem("暂停 / 恢复快捷键", action: #selector(togglePause), to: menu)
        menu.addItem(.separator())
        addMenuItem("退出瞬切", action: #selector(quit), to: menu, key: "q")
        statusItem?.menu = menu
    }

    private func setupApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "瞬切")
        addMenuItem("设置…", action: #selector(showSettings), to: applicationMenu, key: ",")
        applicationMenu.addItem(.separator())
        addMenuItem("退出瞬切", action: #selector(quit), to: applicationMenu, key: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    @objc private func showSettings() {
        switcher.cancel()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1110, height: 840),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "瞬切 WindowPilot"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 16 / 255, green: 17 / 255, blue: 19 / 255, alpha: 1)
            window.minSize = NSSize(width: 1000, height: 740)
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences,
                                                                     showPreview: { [weak self] in self?.switcher.showPinned(demo: true) },
                                                                     showRealWindows: { [weak self] in self?.showWindows() },
                                                                     refresh: { [weak self] in self?.switcher.refreshPermissions() }))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showWindows() {
        switcher.refreshPermissions()
        if preferences.accessibilityGranted { switcher.showPinned() }
        else { showSettings(); preferences.statusMessage = "请在「隐私与权限」中开启辅助功能，然后使用快捷键切换窗口。" }
    }

    @objc private func showDemo() { switcher.showPinned(demo: true) }
    @objc private func togglePause() { preferences.paused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        switcher.shutdown()
    }

    private func renderPreview() {
        guard let index = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        let path = CommandLine.arguments[index + 1]
        // 仅渲染自身视图，验证布局时不获取桌面或其他应用的屏幕内容。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let view = self?.settingsWindow?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
            NSApp.terminate(nil)
        }
    }
}
