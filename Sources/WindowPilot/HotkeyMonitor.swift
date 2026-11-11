import AppKit

enum SwitchAction {
    case begin(backward: Bool, sameApp: Bool)
    case move(Int), commit, cancel, text(String), delete, clearSearch
}

final class HotkeyMonitor {
    var onAction: ((SwitchAction) -> Void)?
    var modifier: SwitchModifier = .option
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var switching = false
    private var releaseToCommit = false
    private var consumedKeys = Set<Int64>()

    @discardableResult func start() -> Bool {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard AXIsProcessTrusted() else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            return monitor.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        switching = false
        releaseToCommit = false
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        consumedKeys = []
    }

    func preparePinnedSession() { switching = true; releaseToCommit = false }
    func endSession() { switching = false; releaseToCommit = false }

    func handleLocal(_ event: NSEvent) -> Bool {
        // 全局钩子已消费的事件不会再到达这里；保留直接送达应用的辅助功能按键。
        guard switching || (event.type == .keyUp && !consumedKeys.isEmpty), let cgEvent = event.cgEvent else { return false }
        return handle(type: cgEvent.type, event: cgEvent)
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            consumedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Diagnostics.shared.record("shortcutTapResumed", ["timedOut": type == .tapDisabledByTimeout])
            if switching { endSession(); onAction?(.cancel) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return consumedKeys.remove(code) != nil }
        if type == .flagsChanged {
            if switching && releaseToCommit && !event.flags.contains(modifier.flag) {
                endSession()
                onAction?(.commit)
            }
            return false
        }
        guard type == .keyDown else { return false }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // 新的物理按下应覆盖可能遗漏的抬起事件；仅吞掉旧按键的系统连发。
        if isRepeat && consumedKeys.contains(code) && (!switching || code == 48 || code == 50) { return true }
        if !isRepeat { consumedKeys.remove(code) }
        let flags = event.flags
        let otherModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        let onlyChosenModifier = flags.intersection(otherModifiers) == modifier.flag
        if (code == 48 || code == 50) && onlyChosenModifier {
            if isRepeat { consumedKeys.insert(code); return true }
            if switching {
                onAction?(.move(flags.contains(.maskShift) ? -1 : 1))
            } else {
                switching = true
                releaseToCommit = true
                onAction?(.begin(backward: flags.contains(.maskShift), sameApp: code == 50))
            }
            consumedKeys.insert(code)
            return true
        }
        guard switching else { return false }
        var action: SwitchAction?
        switch code {
        case 53: endSession(); action = .cancel
        case 36, 76: endSession(); action = .commit
        case 48: action = .move(flags.contains(.maskShift) ? -1 : 1)
        case 123: action = .move(-1)
        case 124: action = .move(1)
        case 125: action = .move(3)
        case 126: action = .move(-3)
        case 51, 117: action = .delete
        default:
            if flags.contains(.maskCommand) && code == 0 { action = .clearSearch }
            else if flags.intersection(otherModifiers.subtracting(modifier.flag)).isEmpty,
                    let text = NSEvent(cgEvent: event)?.characters(byApplyingModifiers: flags.contains(.maskShift) ? [.shift] : []),
                    !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                action = .text(text)
            }
        }
        guard let action else { return false }
        onAction?(action)
        consumedKeys.insert(code)
        return true
    }
}
