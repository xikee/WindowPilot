import AppKit
import SwiftUI

enum SwitchModifier: String, CaseIterable, Identifiable {
    case option, control, command
    var id: String { rawValue }
    var label: String {
        switch self { case .option: return "⌥ Option"; case .control: return "⌃ Control"; case .command: return "⌘ Command" }
    }
    var symbol: String {
        switch self { case .option: return "⌥"; case .control: return "⌃"; case .command: return "⌘" }
    }
    var flag: CGEventFlags {
        switch self { case .option: return .maskAlternate; case .control: return .maskControl; case .command: return .maskCommand }
    }
}

final class Preferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var modifier: SwitchModifier { didSet { defaults.set(modifier.rawValue, forKey: "modifier") } }
    @Published var includeMinimized: Bool { didSet { defaults.set(includeMinimized, forKey: "includeMinimized") } }
    @Published var currentScreenOnly: Bool { didSet { defaults.set(currentScreenOnly, forKey: "currentScreenOnly") } }
    @Published var showThumbnails: Bool { didSet { defaults.set(showThumbnails, forKey: "showThumbnails") } }
    @Published var compact: Bool { didSet { defaults.set(compact, forKey: "compact") } }
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var hotkeyAvailable = false
    @Published var paused = false
    @Published var statusMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["includeMinimized": true, "showThumbnails": true])
        modifier = SwitchModifier(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .option
        includeMinimized = defaults.bool(forKey: "includeMinimized")
        currentScreenOnly = defaults.bool(forKey: "currentScreenOnly")
        showThumbnails = defaults.bool(forKey: "showThumbnails")
        compact = defaults.bool(forKey: "compact")
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        refreshPermissions()
    }
}
