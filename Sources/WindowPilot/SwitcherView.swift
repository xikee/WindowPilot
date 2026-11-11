import SwiftUI

struct WindowCard: View {
    let window: WindowEntry
    let selected: Bool
    var thumbnail: NSImage? = nil
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                ZStack {
                    Color(hex: 0x24262A)
                    if let style = window.demoStyle { DemoPreview(style: style) }
                    else if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
                    else {
                        VStack(spacing: 9) {
                            AppIcon(window: window, size: 38)
                            if window.minimized { Text("已最小化").font(.system(size: 10)).foregroundStyle(Palette.secondary) }
                        }
                    }
                }.aspectRatio(5 / 3, contentMode: .fit).clipped()
            }
            HStack(spacing: 9) {
                AppIcon(window: window, size: compact ? 32 : 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(window.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.text).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(window.appName)
                        if window.minimized { Image(systemName: "minus.square") }
                        if window.hidden { Image(systemName: "eye.slash") }
                    }.font(.system(size: 9)).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "arrow.up.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent) }
            }.padding(compact ? 14 : 11)
        }
        .background(selected ? Color(hex: 0x2B3025) : Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Palette.accent : Palette.border, lineWidth: selected ? 1.7 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.appName)，\(window.title)\(selected ? "，已选中" : "")")
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @ObservedObject var thumbnails: ThumbnailStore
    @ObservedObject var preferences: Preferences

    var body: some View {
        let presentationID = model.presentationID
        let selectedID = model.selectedID
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 26)
                Text("瞬切").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Text(model.sameApp ? "当前应用" : "所有窗口").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                if model.isDemo { Text("交互演示").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.accent).padding(.horizontal, 7).padding(.vertical, 4).background(Palette.accent.opacity(0.1)).clipShape(Capsule()) }
                Spacer()
                Text("\(model.windows.count) 个窗口").font(.system(size: 11)).foregroundStyle(Palette.secondary)
                Button { model.cancel?() } label: { Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(5) }.buttonStyle(.plain).help("取消切换（Esc）")
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 17)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                Text(model.query.isEmpty ? "直接输入，找到想要的窗口…" : model.query).font(.system(size: 12)).foregroundStyle(model.query.isEmpty ? Palette.secondary : Palette.text)
                Spacer()
                if !model.query.isEmpty { Button { model.clearSearch?() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.foregroundStyle(Palette.secondary).padding(12).background(Color.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 24).padding(.bottom, 18)
            if model.loading {
                Spacer(); ProgressView().controlSize(.small); Text("正在寻找窗口…").font(.system(size: 12)).foregroundStyle(Palette.secondary).padding(.top, 10); Spacer()
            } else if model.windows.isEmpty {
                Spacer(); Image(systemName: "rectangle.on.rectangle.slash").font(.system(size: 30)).foregroundStyle(Palette.secondary)
                Text(model.query.isEmpty ? "没有可切换的窗口" : "没有找到“\(model.query)”").font(.system(size: 13)).foregroundStyle(Palette.text).padding(.top, 10)
                Text(model.query.isEmpty ? "打开一个应用窗口后再试试。" : "试试应用名称或窗口标题。 ").font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 3); Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                            ForEach(model.windows) { window in
                                Button { model.choose?(window.id) } label: {
                                    WindowCard(window: window, selected: selectedID == window.id, thumbnail: thumbnails.images[window.id], compact: preferences.compact)
                                }.buttonStyle(.plain).id(window.id)
                                    .onAppear { thumbnails.request(window, presentation: presentationID) }
                                    .onDisappear { thumbnails.remove(window.id, presentation: presentationID) }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 6)
                    }
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID) } }
                    .onChange(of: selectedID) { id in if let id { proxy.scrollTo(id) } }
                }.id(presentationID)
            }
            HStack(spacing: 6) {
                KeyCap(text: "tab"); Text("下一个").padding(.trailing, 9)
                KeyCap(text: "⇧ tab"); Text("上一个").padding(.trailing, 9)
                KeyCap(text: "↵"); Text("切换")
                Spacer()
                if model.isDemo { Text("演示窗口不会切换应用") }
                else { Text("松开 \(preferences.modifier.symbol) 即刻切换") }
                KeyCap(text: "esc")
            }.font(.system(size: 10)).foregroundStyle(Palette.secondary).padding(.horizontal, 24).padding(.vertical, 15)
        }
        .background(Palette.background.opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}
