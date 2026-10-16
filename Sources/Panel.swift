import Cocoa
import Combine
import SwiftUI

final class PanelModel: ObservableObject {
    enum Phase { case listening, thinking, responding, done, error }

    @Published var phase: Phase = .listening
    @Published var transcript = ""
    @Published var response = ""
    @Published var status = ""
    /// Short labels of tools used in this turn, e.g. "Oplo · web search".
    @Published var toolTrail: [String] = []
    @Published var hovering = false
}

// MARK: - Light markdown → SwiftUI

private enum MDBlock {
    case paragraph(AttributedString)
    case bullet(AttributedString)
    case numbered(String, AttributedString)
    case heading(String)
    case code(String)
}

private func inline(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

private func parseBlocks(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var para: [String] = []
    var code: [String]?
    func flush() {
        if !para.isEmpty {
            blocks.append(.paragraph(inline(para.joined(separator: " "))))
            para = []
        }
    }
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") {
            if let c = code {
                blocks.append(.code(c.joined(separator: "\n")))
                code = nil
            } else {
                flush()
                code = []
            }
            continue
        }
        if code != nil {
            code?.append(raw)
            continue
        }
        if line.isEmpty { flush(); continue }
        if line.hasPrefix("#") {
            flush()
            blocks.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
        } else if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
            flush()
            blocks.append(.bullet(inline(String(line.dropFirst(2)))))
        } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                  line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " {
            flush()
            blocks.append(.numbered(String(line[..<dot]), inline(String(line[line.index(dot, offsetBy: 2)...]))))
        } else {
            para.append(line)
        }
    }
    if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
    flush()
    return blocks
}

// MARK: - View

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
    @State private var copied = false

    private var accent: Color {
        switch model.phase {
        case .listening: return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .thinking: return Color(red: 1.0, green: 0.62, blue: 0.2)
        case .responding, .done: return Color(red: 0.42, green: 0.62, blue: 1.0)
        case .error: return Color(red: 1.0, green: 0.78, blue: 0.3)
        }
    }

    private var title: String {
        switch model.phase {
        case .listening: return "Listening"
        case .thinking: return model.status.isEmpty ? "Thinking" : model.status
        case .responding: return model.status.isEmpty ? "Answering" : model.status
        case .done: return "Open Assistant"
        case .error: return "Something went wrong"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if !model.transcript.isEmpty {
                Text(model.transcript)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.bottom, model.response.isEmpty ? 14 : 10)
            }

            if !model.response.isEmpty {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(parseBlocks(model.response).enumerated()), id: \.offset) { _, block in
                            render(block)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
            }

            if model.phase == .done || model.phase == .error {
                footer
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 480, alignment: .leading)
        .background(
            ZStack {
                VisualEffect()
                Color.black.opacity(0.35)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { model.hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(accent.opacity(0.22)).frame(width: 18, height: 18)
                Circle().fill(accent).frame(width: 7, height: 7)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            if model.phase == .thinking || model.phase == .responding {
                ProgressView().controlSize(.mini).padding(.leading, 2)
            }
            Spacer(minLength: 8)
            if !model.toolTrail.isEmpty {
                Text(model.toolTrail.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            Button(action: {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(PanelButtonStyle())
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    @ViewBuilder
    private func render(_ block: MDBlock) -> some View {
        switch block {
        case .paragraph(let a):
            Text(a)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .heading(let s):
            Text(s)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .padding(.top, 4)
        case .bullet(let a):
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(accent.opacity(0.9)).frame(width: 5, height: 5).padding(.top, 7)
                Text(a)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .numbered(let n, let a):
            HStack(alignment: .top, spacing: 8) {
                Text(n + ".")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(accent)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(a)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.92))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .code(let s):
            Text(s)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .textSelection(.enabled)
        }
    }
}

struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.12))
            .clipShape(Capsule())
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Floating, non-activating panel at the top of the screen (doesn't steal focus).
@MainActor
final class PanelController {
    let model: PanelModel
    private let panel: NSPanel
    private let hosting: NSHostingView<PanelView>
    private var observer: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var fadeID = 0

    init() {
        let model = PanelModel()
        self.model = model
        var view = PanelView(model: model)
        hosting = NSHostingView(rootView: view)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting

        view.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.model.response, forType: .string)
        }
        view.onClose = { [weak self] in self?.hideNow() }
        hosting.rootView = view

        observer = model.objectWillChange
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.layout() } }
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        fadeID += 1
        model.hovering = false
        layout()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Hides after `seconds`, but never while the mouse is over the panel.
    func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            var remaining = max(0, seconds)
            while remaining > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                if !self.model.hovering { remaining -= 0.5 }
            }
            guard !Task.isCancelled else { return }
            self?.hideNow()
        }
    }

    func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        model.hovering = false
        guard panel.isVisible else { return }
        fadeID += 1
        let id = fadeID
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeID == id else { return }   // show() happened meanwhile
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func layout() {
        guard panel.isVisible else { return }
        let size = hosting.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let frame = NSRect(x: vf.midX - size.width / 2,
                           y: vf.maxY - size.height - 12,
                           width: size.width,
                           height: size.height)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }
}
