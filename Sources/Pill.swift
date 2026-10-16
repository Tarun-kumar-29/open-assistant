import Cocoa
import Combine
import SwiftUI

/// State for the always-visible floating pill at the bottom of the screen.
final class PillModel: ObservableObject {
    enum State: Equatable { case idle, listening, dictating, thinking, speaking, inserting }

    @Published var state: State = .idle
    /// Microphone level 0…1, updated while listening.
    @Published var level: Float = 0
    @Published var hint = ""
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @State private var pulse = false

    private var expanded: Bool { model.state != .idle }

    private var tint: Color {
        switch model.state {
        case .idle: return .white
        case .listening: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .dictating: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .thinking: return .orange
        case .speaking: return Color(red: 0.4, green: 0.85, blue: 0.5)
        case .inserting: return Color(red: 0.35, green: 0.65, blue: 1.0)
        }
    }

    private var label: String {
        switch model.state {
        case .idle: return ""
        case .listening: return "Listening"
        case .dictating: return "Dictating"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .inserting: return "Typing"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.state == .listening || model.state == .dictating {
                Waveform(level: model.level, tint: tint)
                    .frame(width: 34, height: 16)
            } else if model.state == .thinking || model.state == .inserting {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 1.3 : 0.7)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
            } else if model.state == .speaking {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
            } else {
                // Idle: just a small, dim dot.
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 6, height: 6)
            }
            if expanded {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }
            if model.state == .dictating, !model.hint.isEmpty {
                Text(String(model.hint.suffix(70)))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, expanded ? 12 : 7)
        .frame(height: expanded ? 28 : 16)
        .background(Color.black.opacity(expanded ? 0.78 : 0.45))
        .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .help(model.hint)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.state)
    }
}

/// Five bars that bounce with the microphone level.
struct Waveform: View {
    let level: Float
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let weight: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]
                let h = CGFloat(4 + min(1, level * 2.2) * 12 * weight[i])
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 3, height: h)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

/// Left click toggles listening, right click opens the menu, dragging moves the pill.
final class PillPanelView: NSHostingView<PillView> {
    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private var dragStart: NSPoint?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let now = event.locationInWindow
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged && abs(dx) < 3 && abs(dy) < 3 { return }
        dragged = true
        var origin = window.frame.origin
        origin.x += dx
        origin.y += dy
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onDragEnd?() } else { onClick?() }
        dragStart = nil
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
    override var acceptsFirstResponder: Bool { false }
}

/// Where the pill lives. "custom" is set by dragging it.
enum PillPosition: String, CaseIterable {
    case bottomCenter, bottomLeft, bottomRight, topCenter, topLeft, topRight, custom

    var title: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .topCenter: return "Top Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .custom: return "Where I dragged it"
        }
    }
}

/// When the pill is visible.
enum PillMode: String, CaseIterable {
    case always, activeOnly, never

    var title: String {
        switch self {
        case .always: return "Always (small dot when idle)"
        case .activeOnly: return "Only while listening or talking"
        case .never: return "Never"
        }
    }
}

@MainActor
final class PillController {
    let model = PillModel()
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    /// Called when the user drags the pill somewhere; the app saves the new spot.
    var onMoved: ((PillPosition, CGPoint) -> Void)?

    private(set) var mode: PillMode = .activeOnly
    private(set) var position: PillPosition = .bottomCenter
    private var customPoint: CGPoint?
    private var snoozedUntil: Date?
    private var hideTask: Task<Void, Never>?

    private let panel: NSPanel
    private let host: PillPanelView
    private var observer: AnyCancellable?
    private var hintObserver: AnyCancellable?
    private var lastState: PillModel.State = .idle

    init() {
        let model = self.model
        host = PillPanelView(rootView: PillView(model: model))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 28),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        host.onClick = { [weak self] in self?.onClick?() }
        host.onDragEnd = { [weak self] in
            guard let self else { return }
            let f = self.panel.frame
            self.position = .custom
            self.customPoint = CGPoint(x: f.midX, y: f.midY)
            self.onMoved?(.custom, self.customPoint!)
        }
        host.onRightClick = { [weak self] event in
            guard let self, let menu = self.menuProvider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self.host)
        }

        observer = model.$state.sink { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        hintObserver = model.$hint
            .throttle(for: .milliseconds(120), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.layout() } }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.layout() } }
    }

    func configure(mode: PillMode, position: PillPosition, customPoint: CGPoint?) {
        self.mode = mode
        self.position = position
        self.customPoint = customPoint
        refreshVisibility()
    }

    func setMode(_ m: PillMode) {
        mode = m
        snoozedUntil = nil
        refreshVisibility()
    }

    func setPosition(_ p: PillPosition) {
        position = p
        layout()
    }

    /// Hide until `date` (Wispr-style "hide for 1 hour"); the pill still pops up while active.
    func snooze(until date: Date) {
        snoozedUntil = date
        refreshVisibility()
    }

    var isSnoozed: Bool {
        if let s = snoozedUntil, s > Date() { return true }
        return false
    }

    private func stateChanged(_ state: PillModel.State) {
        guard state != lastState else { return }
        lastState = state
        refreshVisibility()
        // Re-layout a moment later so the panel resizes to the expanded/collapsed pill.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self?.layout()
        }
    }

    private func refreshVisibility() {
        hideTask?.cancel()
        hideTask = nil
        let active = model.state != .idle
        let showIdle = mode == .always && !isSnoozed
        if mode == .never {
            panel.orderOut(nil)
        } else if active || showIdle {
            layout()
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            // Went idle in active-only mode: linger briefly, then fade out.
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !Task.isCancelled, self.model.state == .idle else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    self.panel.animator().alphaValue = 0
                }, completionHandler: {
                    Task { @MainActor in
                        if self.model.state == .idle { self.panel.orderOut(nil) }
                        self.panel.alphaValue = 1
                    }
                })
            }
        }
    }

    private func layout() {
        let size = host.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let margin: CGFloat = 14
        var center: CGPoint
        switch position {
        case .bottomCenter: center = CGPoint(x: vf.midX, y: vf.minY + margin + size.height / 2)
        case .bottomLeft: center = CGPoint(x: vf.minX + margin + size.width / 2, y: vf.minY + margin + size.height / 2)
        case .bottomRight: center = CGPoint(x: vf.maxX - margin - size.width / 2, y: vf.minY + margin + size.height / 2)
        case .topCenter: center = CGPoint(x: vf.midX, y: vf.maxY - margin - size.height / 2)
        case .topLeft: center = CGPoint(x: vf.minX + margin + size.width / 2, y: vf.maxY - margin - size.height / 2)
        case .topRight: center = CGPoint(x: vf.maxX - margin - size.width / 2, y: vf.maxY - margin - size.height / 2)
        case .custom: center = customPoint ?? CGPoint(x: vf.midX, y: vf.minY + margin + size.height / 2)
        }
        // Keep it on screen even if the display changed.
        center.x = min(max(center.x, vf.minX + size.width / 2), vf.maxX - size.width / 2)
        center.y = min(max(center.y, vf.minY + size.height / 2), vf.maxY - size.height / 2)
        let frame = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}
