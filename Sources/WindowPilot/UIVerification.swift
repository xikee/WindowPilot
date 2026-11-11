import AppKit
import SwiftUI

/// 在不申请系统权限的情况下验证自身界面和本地键盘事件。
final class UIVerification {
    private let directory: URL
    private let preferences = Preferences(defaults: UserDefaults(suiteName: "local.windowpilot.ui-verification")!)
    private lazy var controller = SwitcherController(preferences: preferences, useDemoWindowsForShortcuts: true)
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
        guard !sections.isEmpty else {
            checkHeldShortcut(firstKey: 48, sameApp: false) { [self] in
                checkHeldShortcut(firstKey: 50, sameApp: true) { [self] in checkSwitcher() }
            }
            return
        }
        let section = sections.removeFirst()
        window?.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, showPreview: {}, showRealWindows: {}, refresh: {}, initialSection: section))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            save(window?.contentView, name: "settings-\(section.id)")
            renderNextSection()
        }
    }

    private func checkHeldShortcut(firstKey: UInt16, sameApp: Bool, completion: @escaping () -> Void) {
        let mode = sameApp ? "当前应用" : "所有窗口"
        shortcutKey(firstKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            check(controller.model.sameApp == sameApp, "\(mode)：快捷键打开对应范围")
            checkHighlight(2, "\(mode)：按住 Option 唤出时高亮第 2 项")
            shortcutKey(48)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [self] in
                checkHighlight(3, "\(mode)：保持 Option，再点一下 Tab 就高亮第 3 项")
                shortcutKey(48, backward: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [self] in
                    checkHighlight(2, "\(mode)：Shift Tab 立即回到第 2 项")
                    guard let release = CGEvent(source: nil) else { fail("无法创建 Option 抬起事件") }
                    release.flags = []
                    _ = controller.hotkeys.handle(type: .flagsChanged, event: release)
                    check(controller.model.selectedID == nil && controller.presentationView?.window?.isVisible == false,
                          "\(mode)：松开 Option 后关闭面板")
                    completion()
                }
            }
        }
    }

    private func checkHighlight(_ expected: Int, _ description: String) {
        let columns = highlightedColumns()
        guard columns == [expected] else {
            fail("\(description)；实际高亮列：\(columns)，内部选择：\(controller.model.selectedID ?? "无")")
        }
        check(true, description)
    }

    private func shortcutKey(_ code: UInt16, backward: Bool = false) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown)
            else { fail("无法创建快捷键事件") }
            event.flags = backward ? [.maskAlternate, .maskShift] : .maskAlternate
            _ = controller.hotkeys.handle(type: isDown ? .keyDown : .keyUp, event: event)
        }
    }

    private func highlightedColumns() -> [Int] {
        guard let view = controller.presentationView, view.window?.isVisible == true else { return [] }
        let bitmap = render(view)
        // 识别首行卡片顶部的连续高亮描边，避开图标和演示内容中的零散同色像素。
        return (1...3).filter { column in
            let center = bitmap.pixelsWide * (2 * column - 1) / 6
            return (0..<(bitmap.pixelsHigh * 2 / 5)).contains { y in
                [-35, -20, 0, 20, 35].allSatisfy { offset in
                    guard let color = bitmap.colorAt(x: center + offset, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return abs(color.redComponent - 214.0 / 255) < 0.10
                        && abs(color.greenComponent - 242.0 / 255) < 0.10
                        && abs(color.blueComponent - 138.0 / 255) < 0.10
                }
            }
        }
    }

    private func checkSwitcher() {
        checkShortcutAfterMissedKeyUp()
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

    private func checkShortcutAfterMissedKeyUp() {
        let monitor = HotkeyMonitor()
        var starts = 0
        var moves = 0
        var confirms = 0
        monitor.onAction = {
            switch $0 {
            case .begin: starts += 1
            case .move: moves += 1
            case .commit: confirms += 1
            default: break
            }
        }
        guard let tab = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true),
              let release = CGEvent(source: nil) else { fail("无法创建快捷键回归事件") }
        tab.flags = .maskAlternate
        release.flags = []
        _ = monitor.handle(type: .keyDown, event: tab)
        tab.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        _ = monitor.handle(type: .keyDown, event: tab)
        check(starts == 1 && moves == 0, "按住 Tab 的系统连发不会多选一次")
        _ = monitor.handle(type: .flagsChanged, event: release)
        _ = monitor.handle(type: .keyDown, event: tab)
        tab.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        // 不发送第一轮 Tab 抬起，重现切换过程中漏掉抬起事件。
        _ = monitor.handle(type: .keyDown, event: tab)
        _ = monitor.handle(type: .flagsChanged, event: release)
        check(starts == 2 && confirms == 2 && moves == 0, "漏掉 Tab 抬起后，下一次真实按键仍立即切换")
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
        let bitmap = render(view)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("无法编码：\(name)") }
        do { try png.write(to: directory.appendingPathComponent("\(name).png")) }
        catch { fail("无法保存：\(name)，\(error)") }
        print("✓ 界面渲染：\(name)")
    }

    private func render(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("无法渲染界面") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func fail(_ message: String) -> Never { print("✗ \(message)"); exit(1) }
}
