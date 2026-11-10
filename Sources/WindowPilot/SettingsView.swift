import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case overview = "概览", shortcuts = "快捷键", appearance = "外观与行为", permissions = "隐私与权限", about = "关于瞬切"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .shortcuts: return "command"
        case .appearance: return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "少一点寻找，多一点专注。"
        case .shortcuts: return "让手指记住，让思路继续。"
        case .appearance: return "适合你的节奏，也适合你的桌面。"
        case .permissions: return "每一项权限，都有清晰的用途。"
        case .about: return "一个轻巧、安静的窗口切换工具。"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let showPreview: () -> Void
    let showRealWindows: () -> Void
    let refresh: () -> Void
    @State private var section = SettingsSection.overview

    init(preferences: Preferences, showPreview: @escaping () -> Void, showRealWindows: @escaping () -> Void,
         refresh: @escaping () -> Void, initialSection: SettingsSection = .overview) {
        self.preferences = preferences
        self.showPreview = showPreview
        self.showRealWindows = showRealWindows
        self.refresh = refresh
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.border).frame(width: 1)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("工作台").foregroundStyle(Palette.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.secondary.opacity(0.5))
                    Text(section.rawValue).foregroundStyle(Palette.text)
                    Spacer()
                    Circle().fill(preferences.hotkeyAvailable && !preferences.paused ? Palette.accent : Color(hex: 0xE0B578)).frame(width: 5, height: 5)
                    Text(preferences.paused ? "已暂停" : preferences.hotkeyAvailable ? "正在后台运行" : "等待授权").foregroundStyle(Palette.secondary)
                }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 36).frame(height: 55)
                Rectangle().fill(Palette.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if section == .overview { overview }
                        else {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(section.rawValue).font(.system(size: 29, weight: .semibold))
                                Text(section.subtitle).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                            }.padding(.top, 8)
                            switch section {
                            case .shortcuts: shortcutSettings
                            case .appearance: appearanceSettings
                            case .permissions: permissionSettings
                            case .about: about
                            case .overview: EmptyView()
                            }
                        }
                        if let message = preferences.statusMessage {
                            HStack { Image(systemName: "info.circle"); Text(message); Spacer(); Button("关闭") { preferences.statusMessage = nil }.buttonStyle(.plain) }
                                .font(.system(size: 11)).foregroundStyle(Palette.accent).padding(15).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(36).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 1000, minHeight: 740)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                BrandMark(size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("瞬切").font(.system(size: 20, weight: .semibold))
                    Text("WINDOWPILOT").font(.system(size: 8, weight: .medium)).tracking(1.6).foregroundStyle(Palette.secondary)
                }
            }.padding(.top, 52).padding(.bottom, 39).padding(.horizontal, 24)
            Text("你的空间").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.secondary.opacity(0.65)).padding(.horizontal, 27).padding(.bottom, 12)
            ForEach(SettingsSection.allCases.filter { $0 != .about }) { item in navigation(item) }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) { Image(systemName: "sparkle"); Text("专注在当下").fontWeight(.medium) }.foregroundStyle(Palette.accent)
                Text("窗口之间，\n思路不必重新开始。").foregroundStyle(Palette.secondary).lineSpacing(5)
            }.font(.system(size: 10)).padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 18).padding(.bottom, 21)
            navigation(.about)
            HStack { Text("版本 1.0.0"); Spacer(); Text("原生 macOS") }.font(.system(size: 8)).foregroundStyle(Palette.secondary.opacity(0.6)).padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 23)
        }.frame(width: 208).background(Palette.sidebar)
    }

    private func navigation(_ item: SettingsSection) -> some View {
        Button { section = item; refresh() } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 18)
                Text(item.rawValue).font(.system(size: 12, weight: section == item ? .semibold : .regular))
                Spacer()
                if section == item { RoundedRectangle(cornerRadius: 2).fill(Palette.accent).frame(width: 3, height: 13) }
            }.foregroundStyle(section == item ? Palette.accent : Palette.secondary).padding(.horizontal, 13).frame(height: 41)
                .background(section == item ? Palette.accent.opacity(0.07) : .clear).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 4)
    }

    private var overview: some View {
        Group {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Rectangle().fill(Palette.accent).frame(width: 17, height: 1)
                        Text("LESS FRICTION. MORE FLOW.").font(.system(size: 8, weight: .medium)).tracking(1.7).foregroundStyle(Palette.accent)
                    }
                    Text("切换窗口，不打断思路。").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                    Text("所有窗口，一眼找到。下一步，交给肌肉记忆。").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 10)
                HStack(spacing: 7) { KeyCap(text: preferences.modifier.symbol, large: true); KeyCap(text: "tab", large: true) }
            }.padding(.top, 2)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    HStack(spacing: 8) { Image(systemName: "rectangle.stack").foregroundStyle(Palette.accent); Text("你的窗口，井然有序").fontWeight(.medium) }.font(.system(size: 12))
                    Text("界面演示").font(.system(size: 9)).foregroundStyle(Palette.secondary).padding(.horizontal, 7).padding(.vertical, 4).background(Color.white.opacity(0.04)).clipShape(Capsule())
                    Spacer()
                    Text("6 个窗口 · 6 个应用").font(.system(size: 9)).foregroundStyle(Palette.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 11), count: 3), spacing: 11) {
                    ForEach(DemoWindows.entries) { window in WindowCard(window: window, selected: window.demoStyle == 1) }
                }
                HStack(spacing: 5) {
                    KeyCap(text: preferences.modifier.symbol); Text("按住").padding(.trailing, 9)
                    KeyCap(text: "tab"); Text("选择").padding(.trailing, 9)
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10)); Text("松开即切换")
                    Spacer()
                    Button(action: showPreview) { HStack(spacing: 6) { Image(systemName: "play.fill").font(.system(size: 9)); Text("体验一下") } }.buttonStyle(QuietButton())
                }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
            }.padding(20).background(Palette.surface.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.border))
            HStack(spacing: 16) {
                ZStack { RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.08)); Image(systemName: preferences.hotkeyAvailable ? "checkmark.shield" : "lock.open").foregroundStyle(Palette.accent).font(.system(size: 20)) }.frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(preferences.hotkeyAvailable ? "准备就绪，试试你的新快捷键。" : "只差一步，让瞬切开始工作。").font(.system(size: 12, weight: .medium))
                    Text(preferences.hotkeyAvailable ? "\(preferences.modifier.symbol) Tab 切换窗口 · \(preferences.modifier.symbol) ` 切换同应用窗口" : "开启辅助功能以切换窗口；开启屏幕录制以显示预览。").font(.system(size: 10)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                if preferences.hotkeyAvailable {
                    Button("查看真实窗口", action: showRealWindows).buttonStyle(AccentButton())
                } else {
                    Button { section = .permissions; refresh() } label: { HStack(spacing: 7) { Text("完成设置"); Image(systemName: "arrow.right") } }.buttonStyle(AccentButton())
                }
            }.padding(18).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
            HStack(spacing: 22) {
                Label("Swift 原生构建", systemImage: "swift")
                Label("窗口级切换", systemImage: "rectangle.on.rectangle")
                Label("数据留在本机", systemImage: "lock")
                Spacer()
                Text("为流畅的每一天。").foregroundStyle(Palette.secondary.opacity(0.5))
            }.font(.system(size: 9)).foregroundStyle(Palette.secondary)
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 23) {
            settingsCard {
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text("主修饰键").font(.system(size: 13, weight: .medium)); Text("快捷键修改后立即生效。选择 Command 会接管系统 ⌘ Tab。").font(.system(size: 11)).foregroundStyle(Palette.secondary) }
                    Spacer()
                    Picker("主修饰键", selection: $preferences.modifier) { ForEach(SwitchModifier.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 150)
                }
            }
            settingsCard {
                VStack(spacing: 0) {
                    shortcutRow("唤起切换器 / 下一个窗口", keys: [preferences.modifier.symbol, "tab"])
                    Divider().overlay(Palette.border)
                    shortcutRow("上一个窗口", keys: [preferences.modifier.symbol, "⇧", "tab"])
                    Divider().overlay(Palette.border)
                    shortcutRow("仅切换当前应用的窗口", keys: [preferences.modifier.symbol, "`"])
                    Divider().overlay(Palette.border)
                    shortcutRow("确认切换", keys: ["松开 " + preferences.modifier.symbol, "或 ↵"])
                    Divider().overlay(Palette.border)
                    shortcutRow("取消，回到原来的窗口", keys: ["esc"])
                }
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("不用离开键盘", systemImage: "keyboard").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                    Text("切换器打开时，直接输入应用名称或窗口标题进行搜索。支持多个关键词；用方向键选择，退格删除，Esc 退出。也可以用鼠标点击窗口。").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(6)
                }
            }
        }
    }

    private var appearanceSettings: some View {
        VStack(spacing: 18) {
            settingsCard {
                VStack(spacing: 23) {
                    toggleRow("紧凑视图", detail: "仅显示应用图标和窗口标题，容纳更多窗口。", binding: $preferences.compact)
                    Divider().overlay(Palette.border)
                    toggleRow("显示窗口缩略图", detail: "打开切换器时按需生成预览，需要屏幕录制权限。", binding: $preferences.showThumbnails)
                }
            }
            settingsCard {
                VStack(spacing: 23) {
                    toggleRow("包含最小化窗口", detail: "切换时自动恢复选中的最小化窗口。", binding: $preferences.includeMinimized)
                    Divider().overlay(Palette.border)
                    toggleRow("仅当前显示器", detail: "仅列出鼠标所在显示器上的窗口。", binding: $preferences.currentScreenOnly)
                    Divider().overlay(Palette.border)
                    toggleRow("暂停全局快捷键", detail: "暂时停用键盘监听，可随时恢复。", binding: $preferences.paused)
                }
            }
            HStack { Image(systemName: "info.circle"); Text("切换器会出现在鼠标所在的显示器。设置自动保存在本机。") }.font(.system(size: 11)).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            permissionCard(symbol: "hand.raised", title: "辅助功能", required: "窗口切换必需", granted: preferences.accessibilityGranted,
                           detail: "读取应用窗口标题、位置，监听切换快捷键，并将选中的窗口置于前台。请在系统设置中添加并开启「瞬切」。", button: "打开系统设置", action: preferences.openAccessibilitySettings)
            permissionCard(symbol: "rectangle.dashed.badge.record", title: "屏幕录制", required: "窗口预览可选", granted: preferences.screenRecordingGranted,
                           detail: "为切换器生成窗口缩略图。只在切换器打开期间处理，关闭后清空内存；不保存截图，也不上传。", button: "开启窗口预览", action: preferences.requestScreenRecording)
            Button { refresh() } label: { Label("重新检查权限", systemImage: "arrow.clockwise") }.buttonStyle(QuietButton())
            if preferences.accessibilityGranted && !preferences.hotkeyAvailable && !preferences.paused {
                Text("辅助功能已授权，但快捷键监听尚未建立。请从菜单栏退出并重新打开瞬切；同时检查是否有其他窗口切换工具占用快捷键。").font(.system(size: 12)).foregroundStyle(Color(hex: 0xE0B578)).lineSpacing(5)
            }
            settingsCard {
                VStack(alignment: .leading, spacing: 11) {
                    Label("只为完成眼前这件事", systemImage: "lock.shield").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                    Text("无需账户，没有网络请求、广告或统计。关闭缩略图后仍可按标题切换。权限随时可以在 macOS「隐私与安全性」中撤回。系统在授权后可能要求重新打开应用。").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(6)
                }
            }
        }
    }

    private var about: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 23) {
                HStack(spacing: 18) { BrandMark(size: 64); VStack(alignment: .leading, spacing: 7) { Text("瞬切 WindowPilot").font(.system(size: 24, weight: .semibold)); Text("版本 1.0.0 · macOS 13+").font(.system(size: 12)).foregroundStyle(Palette.secondary) } }
                Text("借鉴 AltTab 的窗口切换体验，使用 Swift、AppKit 和 SwiftUI 独立实现。按窗口选择目标，让每一次切换都更直接。").font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(7)
                Divider().overlay(Palette.border)
                Text("当前版本使用系统公开 API。其他桌面和全屏应用的窗口是否可见取决于 macOS 与应用的辅助功能实现；不提供完整的跨 Space 枚举保证。受保护的内容可能无法预览。").font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(7)
                Button(action: showPreview) { Label("打开交互演示", systemImage: "play") }.buttonStyle(AccentButton())
            }
        }
    }

    private func permissionCard(symbol: String, title: String, required: String, granted: Bool, detail: String, button: String, action: @escaping () -> Void) -> some View {
        settingsCard {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: symbol).font(.system(size: 23)).foregroundStyle(Palette.accent).frame(width: 34).padding(.top, 2)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 9) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        Text(required).font(.system(size: 9)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Label(granted ? "已授权" : "未授权", systemImage: granted ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 11)).foregroundStyle(granted ? Palette.accent : Palette.secondary)
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineSpacing(6)
                    Button(button, action: action).buttonStyle(QuietButton())
                }
            }
        }
    }

    private func shortcutRow(_ label: String, keys: [String]) -> some View {
        HStack { Text(label).font(.system(size: 12)); Spacer(); ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(text: key) } }.padding(.vertical, 15)
    }

    private func toggleRow(_ title: String, detail: String, binding: Binding<Bool>) -> some View {
        HStack { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(Palette.secondary) }; Spacer(minLength: 24); Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch).tint(Palette.accent).controlSize(.small) }
    }

    private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.border))
    }
}
