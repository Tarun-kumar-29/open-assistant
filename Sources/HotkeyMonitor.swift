import Cocoa

/// Watches a push-to-talk key system-wide with a CGEvent tap.
/// Needs Accessibility (and on newer macOS, Input Monitoring) permission.
final class HotkeyMonitor {
    enum Mode {
        case modifier(keyCodes: [Int64], mask: UInt64)
        case key(keyCode: Int64)
    }

    var onPress: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    /// Fired when the key was used as part of a shortcut (e.g. Fn+arrow) instead of push-to-talk.
    var onCancel: (@MainActor () -> Void)?
    /// Fired for a quick tap (released before push-to-talk kicked in).
    var onTap: (@MainActor () -> Void)?

    /// How long the key must be held before it counts as push-to-talk.
    /// Gives Fn+key shortcuts time to show they're a shortcut, so they never disturb the assistant.
    private let holdDelay: TimeInterval = 0.2
    private var pendingPress: DispatchWorkItem?
    private var pressFired = false

    let mode: Mode
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var chorded = false

    init(spec: String) { mode = HotkeyMonitor.parse(spec) }

    static func isDisabled(_ spec: String) -> Bool {
        let s = spec.lowercased().trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s == "none" || s == "off"
    }

    static func parse(_ spec: String) -> Mode {
        let s = spec.lowercased().trimmingCharacters(in: .whitespaces)
        switch s {
        case "rightoption", "right_option", "ropt": return .modifier(keyCodes: [61], mask: 0x40)      // right Option only
        case "rightcommand", "right_command", "rcmd": return .modifier(keyCodes: [54], mask: 0x10)      // right Command only
        case "rightcontrol", "right_control", "rctrl": return .modifier(keyCodes: [62], mask: 0x2000)    // right Control only
        default:
            if s.hasPrefix("keycode:"), let n = Int64(s.dropFirst("keycode:".count)) { return .key(keyCode: n) }
            // Fn / Globe: keycode 63 on built-in keyboards, 179 on some external ones.
            return .modifier(keyCodes: [63, 179], mask: CGEventFlags.maskSecondaryFn.rawValue)
        }
    }

    static func describe(_ spec: String) -> String {
        switch parse(spec) {
        case .modifier(let codes, _):
            switch codes.first {
            case 61: return "Right Option"
            case 54: return "Right Command"
            case 62: return "Right Control"
            default: return "Fn"
            }
        case .key(let code): return "key \(code)"
        }
    }

    /// Returns false if macOS refused the event tap (permission not granted yet).
    func start() -> Bool {
        stop()
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch mode {
        case .modifier(let codes, let mask):
            if type == .flagsChanged && codes.contains(code) {
                setDown(event.flags.rawValue & mask != 0)
            } else if type == .keyDown && isDown {
                chorded = true   // e.g. Fn+Delete — a shortcut, not push-to-talk
                pendingPress?.cancel()
                pendingPress = nil
            }
            return Unmanaged.passUnretained(event)

        case .key(let keyCode):
            guard code == keyCode, type == .keyDown || type == .keyUp else {
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { setDown(true) }
            } else {
                setDown(false)
            }
            return nil   // swallow the key so it doesn't reach other apps
        }
    }

    private func setDown(_ down: Bool) {
        guard down != isDown else { return }
        isDown = down
        if down {
            chorded = false
            pressFired = false
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isDown, !self.chorded else { return }
                self.pressFired = true
                let cb = self.onPress
                Task { @MainActor in cb?() }
            }
            pendingPress = work
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
        } else {
            pendingPress?.cancel()
            pendingPress = nil
            let cb: (@MainActor () -> Void)?
            if pressFired {
                cb = chorded ? onCancel : onRelease
            } else {
                cb = chorded ? nil : onTap
            }
            Task { @MainActor in cb?() }
        }
    }
}
