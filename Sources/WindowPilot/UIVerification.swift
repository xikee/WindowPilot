import AppKit
import SwiftUI

/// 在不申请系统权限的情况下验证自身界面和本地键盘事件。
final class UIVerification {
    private let directory: URL
    private let preferences = Preferences(defaults: UserDefaults(suiteName: "local.windowpilot.ui-verification")!)
    private lazy var controller = SwitcherController(preferences: preferences)
    private var window: NSWindow?
    private var sections = SettingsSection.allCases
    private var checks = 0

    init(directory: URL) { self.directory = directory }

    func start() {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { fail("无法创建验证目录：\(error)") }
        preferences.modifier = .option
        preferences.compact = false
        preferences.paused = false
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1110, height: 960), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "瞬切 · 界面验证"
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        renderNextSection()
    }

    private func renderNextSection() {
        guard !sections.isEmpty else { checkSwitcher(); return }
        let section = sections.removeFirst()
        window?.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, showPreview: {}, showRealWindows: {}, refresh: {}, initialSection: section))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            save(window?.contentView, name: "settings-\(section.id)")
            renderNextSection()
        }
    }

    private func checkSwitcher() {
        controller.showPinned(demo: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            check(controller.model.windows.count == 6, "演示窗口加载")
            check(controller.model.selectedID == "demo-1", "初始窗口选择")
            save(controller.presentationView, name: "switcher")
            key(48, characters: "\t")
            check(controller.model.selectedID == "demo-2", "Tab 前进")
            key(48, characters: "\t", modifiers: .shift)
            check(controller.model.selectedID == "demo-1", "Shift Tab 后退")
            key(125, characters: "\u{F701}")
            check(controller.model.selectedID == "demo-4", "方向键按行移动")
            key(126, characters: "\u{F700}")
            check(controller.model.selectedID == "demo-1", "方向键返回上一行")
            for (code, character): (UInt16, String) in [(1, "s"), (0, "a"), (3, "f"), (0, "a"), (15, "r"), (34, "i")] { key(code, characters: character) }
            check(controller.model.query.lowercased() == "safari", "按键转换为搜索文本")
            check(controller.model.windows.count == 1 && controller.model.windows.first?.appName == "Safari", "按应用名称筛选")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                save(controller.presentationView, name: "switcher-search")
                for _ in 0..<6 { key(51, characters: "\u{7F}") }
                check(controller.model.query.isEmpty && controller.model.windows.count == 6, "退格清除后恢复所有窗口")
                key(6, characters: "z")
                check(controller.model.windows.isEmpty, "无匹配搜索结果")
                key(53, characters: "\u{1B}")
                check(controller.model.windows.isEmpty && controller.model.selectedID == nil, "Escape 退出并释放窗口列表")
                preferences.compact = true
                controller.showPinned(demo: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                    save(controller.presentationView, name: "switcher-compact")
                    controller.model.choose?("demo-2")
                    check(controller.model.windows.isEmpty, "鼠标选择完成并关闭演示")
                    print("\(checks) 个界面与事件检查通过；截图：\(directory.path)")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func key(_ code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { fail("无法创建键盘事件") }
            _ = controller.hotkeys.handleLocal(event)
        }
    }

    private func check(_ condition: Bool, _ description: String) {
        guard condition else { fail(description) }
        checks += 1
        print("✓ \(description)")
    }

    private func save(_ view: NSView?, name: String) {
        guard let view else { fail("缺少视图：\(name)") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("无法渲染：\(name)") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("无法编码：\(name)") }
        do { try png.write(to: directory.appendingPathComponent("\(name).png")) }
        catch { fail("无法保存：\(name)，\(error)") }
        print("✓ 界面渲染：\(name)")
    }

    private func fail(_ message: String) -> Never { print("✗ \(message)"); exit(1) }
}
