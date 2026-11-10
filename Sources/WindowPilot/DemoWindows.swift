import AppKit
import SwiftUI

enum DemoWindows {
    static let entries: [WindowEntry] = [
        ("Safari", "周末，去山里走走", 0),
        ("Visual Studio Code", "WindowPilot · Switcher.swift", 1),
        ("设计工作台", "新想法，有了形状", 2),
        ("备忘录", "留一点时间给自己", 3),
        ("访达", "最近的灵感", 4),
        ("音乐", "A little room to focus", 5)
    ].enumerated().map { index, data in
        WindowEntry(id: "demo-\(index)", windowID: nil, pid: 0, appName: data.0, title: data.1,
                    bounds: CGRect(x: 0, y: 0, width: 1280, height: 800), minimized: false, hidden: false, element: nil, demoStyle: data.2)
    }
}

struct AppIcon: View {
    let window: WindowEntry
    var size: CGFloat = 26
    private var image: NSImage? { window.pid > 0 ? NSRunningApplication(processIdentifier: window.pid)?.icon : nil }
    private var colors: [Color] { [.blue, Color(hex: 0x419BD7), Color(hex: 0xC08AF4), .yellow, .blue, Color(hex: 0xEE6776)] }
    private var symbols: [String] { ["safari.fill", "chevron.left.forwardslash.chevron.right", "square.stack.3d.up.fill", "note.text", "folder.fill", "music.note"] }
    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            let index = (window.demoStyle ?? 0) % colors.count
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.23).fill(colors[index].gradient)
                Image(systemName: symbols[index]).font(.system(size: size * 0.53, weight: .semibold)).foregroundStyle(.white)
            }.frame(width: size, height: size)
        }
    }
}

/// 仅用于明确标注的交互演示，不作为真实窗口截图。
struct DemoPreview: View {
    let style: Int
    var body: some View {
        GeometryReader { geo in
            content.frame(width: 500, height: 300).scaleEffect(geo.size.width / 500, anchor: .topLeading)
        }.aspectRatio(5 / 3, contentMode: .fit).clipped()
    }

    @ViewBuilder private var content: some View {
        switch style {
        case 0: landscape
        case 1: code
        case 2: design
        case 3: notes
        case 4: finder
        default: music
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 5) { ForEach([0xEC6A61, 0xE9BD4F, 0x62BD55], id: \.self) { color in Circle().fill(Color(hex: UInt32(color))).frame(width: 7, height: 7) } }
    }

    private var landscape: some View {
        VStack(spacing: 0) {
            HStack { trafficLights; Spacer(); Text("fieldnotes.co").font(.system(size: 9)); Spacer(); Image(systemName: "plus") }
                .foregroundStyle(Color(hex: 0x7D8280)).padding(11).background(Color(hex: 0xECEEE8))
            ZStack {
                LinearGradient(colors: [Color(hex: 0xB5C8C4), Color(hex: 0xDCE1CA)], startPoint: .top, endPoint: .bottom)
                MountainShape().fill(Color(hex: 0x657E69)).offset(x: -25, y: 60)
                MountainShape().fill(Color(hex: 0x3E5F53)).offset(x: 140, y: 105)
                VStack(spacing: 8) {
                    Text("F I E L D N O T E S").font(.system(size: 9, weight: .medium))
                    Text("Take the slow road.").font(.system(size: 33, weight: .regular, design: .serif))
                    Text("A little closer to the outside.").font(.system(size: 11))
                    Capsule().fill(.white.opacity(0.9)).frame(width: 80, height: 24).overlay(Text("EXPLORE  ↗").font(.system(size: 8)).foregroundStyle(Color(hex: 0x3A5149))).padding(.top, 10)
                }.foregroundStyle(.white).offset(y: -8)
            }
        }.frame(height: 300)
    }

    private var code: some View {
        VStack(spacing: 0) {
            HStack { trafficLights; Spacer(); Text("WindowPilot — Switcher.swift").font(.system(size: 9)); Spacer() }.foregroundStyle(.gray).padding(10).background(Color(hex: 0x25262B))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("EXPLORER").font(.system(size: 8, weight: .bold)).foregroundStyle(.gray)
                    ForEach(["⌄ WindowPilot", "  Sources", "    App.swift", "    Switcher.swift", "    Theme.swift", "  Package.swift"], id: \.self) { Text($0).font(.system(size: 8)).foregroundStyle(Color(hex: 0x9FA6B2)) }
                    Spacer()
                }.padding(14).frame(width: 120).background(Color(hex: 0x191B20))
                VStack(alignment: .leading, spacing: 9) {
                    Text("Switcher.swift  ×").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).padding(.bottom, 12)
                    ForEach(Array(["import SwiftUI", "", "struct Switcher: View {", "    @State var selected = 0", "", "    var body: some View {", "        WindowGrid(selection: $selected)", "            .padding(24)", "            .animation(.spring())", "    }", "}"].enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 15) { Text(String(index + 1)).foregroundStyle(.gray.opacity(0.5)).frame(width: 12); Text(line).foregroundStyle(index == 0 || index == 2 ? Color(hex: 0xBAA1EA) : Color(hex: 0xA4CEB0)) }.font(.system(size: 9, design: .monospaced))
                    }
                    Spacer()
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0x1F2127))
            }
            HStack { Text("main*"); Spacer(); Text("Swift   UTF-8   ✓") }.font(.system(size: 8)).foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 12).frame(height: 18).background(Color(hex: 0x365D82))
        }.frame(height: 300)
    }

    private var design: some View {
        VStack(spacing: 0) {
            HStack { trafficLights; Spacer(); Text("Everyday studio / Explorations").font(.system(size: 9)); Spacer(); Image(systemName: "play.fill").font(.system(size: 8)) }.foregroundStyle(.gray).padding(10).background(Color(hex: 0xF5F3F0))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 17) { Text("Layers").bold(); Text("⌄ Canvas"); Text("  ◇ Everyday"); Text("  ◇ Shapes"); Spacer() }.font(.system(size: 9)).foregroundStyle(Color(hex: 0x8B898B)).padding(14).frame(width: 102).background(Color(hex: 0xFAF9F7))
                ZStack {
                    Color(hex: 0xE9E6E1)
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xE2C3F0)).frame(width: 250, height: 188).rotationEffect(.degrees(-5))
                    RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x2C3C35)).frame(width: 250, height: 188).rotationEffect(.degrees(4))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("EVERYDAY®").font(.system(size: 9, weight: .bold))
                        Text("Make room\nfor good things.").font(.system(size: 28, weight: .medium, design: .serif))
                        HStack { Text("A NEW PERSPECTIVE").font(.system(size: 7)); Spacer(); Image(systemName: "asterisk").font(.system(size: 35)) }
                    }.foregroundStyle(Color(hex: 0xD6F28A)).padding(23).frame(width: 250, height: 188)
                }
            }
        }.frame(height: 300)
    }

    private var notes: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                trafficLights.padding(.bottom, 12)
                Text("备忘录").font(.system(size: 12, weight: .semibold))
                ForEach(["所有备忘录   12", "灵感收集       8", "生活碎片       4"], id: \.self) { Text($0).font(.system(size: 10)) }
                Spacer()
            }.foregroundStyle(Color(hex: 0x8D8371)).padding(17).frame(width: 145).background(Color(hex: 0xEAE5DB))
            VStack(alignment: .leading, spacing: 15) {
                Text("11 月 10 日，星期二").font(.system(size: 9)).foregroundStyle(Color(hex: 0xA69D8B))
                Text("留一点时间\n给自己。").font(.system(size: 26, weight: .semibold)).lineSpacing(5)
                Text("不必每一分钟，都有一个目的。").font(.system(size: 10))
                ForEach(["去楼下喝杯咖啡", "听完那张喜欢的专辑", "在日落前散个步"], id: \.self) { text in HStack(spacing: 8) { Circle().stroke(Color(hex: 0xC5AC71)).frame(width: 10, height: 10); Text(text).font(.system(size: 10)) } }
                Spacer()
            }.foregroundStyle(Color(hex: 0x504A40)).padding(28).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xFAF7F0))
        }.frame(height: 300)
    }

    private var finder: some View {
        VStack(spacing: 0) {
            HStack { trafficLights; Spacer(); Text("最近的灵感").font(.system(size: 10, weight: .semibold)); Spacer(); Image(systemName: "square.grid.2x2") }.foregroundStyle(.gray).padding(12).background(Color(hex: 0xE7E9ED))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) { Text("个人收藏").font(.system(size: 8)); Label("最近使用", systemImage: "clock"); Label("桌面", systemImage: "desktopcomputer"); Label("文稿", systemImage: "doc"); Label("下载", systemImage: "arrow.down.circle"); Spacer() }.font(.system(size: 9)).foregroundStyle(Color(hex: 0x657080)).padding(16).frame(width: 118).background(Color(hex: 0xE6EBF0))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 20) {
                    ForEach(["Projects", "灵感收集", "Photography", "音乐", "Archive", "Personal"], id: \.self) { name in
                        VStack(spacing: 7) { Image(systemName: "folder.fill").font(.system(size: 42)).foregroundStyle(Color(hex: 0x70B9E6).gradient); Text(name).font(.system(size: 8)).foregroundStyle(Color(hex: 0x616774)) }
                    }
                }.padding(22).frame(maxHeight: .infinity).background(Color(hex: 0xFAFBFD))
            }
        }.frame(height: 300)
    }

    private var music: some View {
        HStack(spacing: 22) {
            ZStack {
                Color(hex: 0xB4C8B5)
                Circle().fill(Color(hex: 0xDCE5D3)).frame(width: 125, height: 125).offset(x: 40, y: -35)
                MountainShape().fill(Color(hex: 0x668C75)).offset(y: 55)
                VStack { Spacer(); Text("S O F T  F O C U S").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).padding(18) }
            }.frame(width: 178, height: 204).clipped()
            VStack(alignment: .leading, spacing: 12) {
                Text("为此刻而播放").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4))
                Text("A little room\nto focus.").font(.system(size: 26, weight: .medium, design: .serif))
                Text("Soft Focus · 24 首歌曲").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 20) { Image(systemName: "backward.end.fill"); Image(systemName: "pause.circle.fill").font(.system(size: 32)); Image(systemName: "forward.end.fill") }.font(.system(size: 11)).padding(.top, 8)
                Capsule().fill(.white.opacity(0.2)).frame(height: 2).overlay(alignment: .leading) { Capsule().fill(Palette.accent).frame(width: 55, height: 2) }
            }.foregroundStyle(.white)
        }.padding(30).frame(width: 500, height: 300).background(Color(hex: 0x25362E))
    }
}

private struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: -rect.width * 0.3, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width * 0.18, y: rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.width * 0.32, y: rect.height * 0.3))
        path.addLine(to: CGPoint(x: rect.width * 0.5, y: -rect.height * 0.15))
        path.addLine(to: CGPoint(x: rect.width * 1.2, y: rect.height))
        path.closeSubpath()
        return path
    }
}
