import Cocoa
import SwiftUI

/// Opens the Connectors window (one instance, reused).
@MainActor
final class ConnectorsWindowController {
    private var window: NSWindow?

    func show(manager: ConnectorManager) {
        if window == nil {
            let host = NSHostingController(rootView: ConnectorsView(manager: manager))
            let w = NSWindow(contentViewController: host)
            w.title = "Connectors"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 700, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var config: ConnectorConfig
    var isNew: Bool
    var note: String?
}

struct ConnectorsView: View {
    @ObservedObject var manager: ConnectorManager
    @State private var editor: EditorRequest?
    @State private var showCatalog = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connectors").font(.system(size: 20, weight: .semibold))
                    Text("Let Open Assistant use your apps and tools. Say things like “what's assigned to me in Linear?”")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu {
                    Button("Browse Catalog…") { showCatalog = true }
                    Divider()
                    Button("Custom Remote Server…") { newCustom(.remote) }
                    Button("Custom Local Server…") { newCustom(.local) }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .fixedSize()
            }
            .padding(20)

            Divider()

            if manager.connectors.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No connectors yet").font(.headline)
                    Text("Add Linear, Notion, GitHub, your files and more.")
                        .foregroundColor(.secondary)
                    Button("Browse Catalog") { showCatalog = true }
                        .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(manager.connectors) { c in
                        ConnectorRow(
                            config: c,
                            runtime: manager.runtime[c.id] ?? ConnectorManager.Runtime(),
                            manager: manager,
                            onEdit: { editor = EditorRequest(config: c, isNew: false, note: nil) }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .sheet(isPresented: $showCatalog) {
            CatalogView(onPick: { entry in
                showCatalog = false
                // Let the catalog sheet close before opening the editor sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    editor = EditorRequest(config: entry.config, isNew: true, note: entry.note)
                }
            }, onCancel: { showCatalog = false })
        }
        .sheet(item: $editor) { req in
            ConnectorEditor(request: req, onSave: { cfg in
                manager.upsert(cfg, isNew: req.isNew)
                editor = nil
            }, onCancel: { editor = nil })
        }
    }

    private func newCustom(_ kind: ConnectorConfig.Kind) {
        let cfg = ConnectorConfig(id: "", name: "", kind: kind)
        editor = EditorRequest(config: cfg, isNew: true, note: kind == .local
            ? "Runs a command on your Mac, e.g. npx -y some-mcp-server. Use the full path if the command isn't found."
            : "Paste the server's MCP URL. If it needs sign-in you'll get a Log In button after adding.")
    }
}

struct ConnectorRow: View {
    let config: ConnectorConfig
    let runtime: ConnectorManager.Runtime
    @ObservedObject var manager: ConnectorManager
    let onEdit: () -> Void
    @State private var showTools = false

    private var errorMessage: String? {
        guard config.enabled, case .error(let message) = runtime.status else { return nil }
        return message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: config.kind == .remote ? "globe" : "terminal")
                .font(.system(size: 17))
                .foregroundColor(.accentColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(config.name).font(.system(size: 14, weight: .semibold))
                    StatusPill(status: config.enabled ? runtime.status : .off)
                }
                Text(config.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let message = errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !runtime.tools.isEmpty {
                    DisclosureGroup("\(runtime.tools.count) tools", isExpanded: $showTools) {
                        Text(runtime.tools.map(\.name).joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            }

            Spacer(minLength: 8)

            if config.enabled {
                switch runtime.status {
                case .needsLogin:
                    Button("Log In") { manager.login(config.id) }
                        .buttonStyle(.borderedProminent)
                case .error, .off:
                    Button("Retry") { manager.connect(config.id) }
                case .connecting:
                    ProgressView().controlSize(.small)
                case .connected:
                    EmptyView()
                }
            }

            Toggle("", isOn: Binding(
                get: { config.enabled },
                set: { manager.setEnabled(config.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            Menu {
                Button("Edit…", action: onEdit)
                if config.kind == .remote {
                    Button("Log Out") { manager.logout(config.id) }
                } else {
                    Button("Show Log") { _ = NSWorkspace.shared.open(manager.logURL(config.id)) }
                }
                Divider()
                Button("Remove", role: .destructive) { manager.remove(config.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }
}

struct StatusPill: View {
    let status: ConnectorManager.Status

    private var info: (String, Color) {
        switch status {
        case .off: return ("Off", .gray)
        case .connecting: return ("Connecting", .orange)
        case .connected: return ("Connected", .green)
        case .needsLogin: return ("Needs login", .blue)
        case .error: return ("Error", .red)
        }
    }

    var body: some View {
        Text(info.0)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(info.1.opacity(0.18))
            .foregroundColor(info.1)
            .clipShape(Capsule())
    }
}

struct CatalogView: View {
    let onPick: (CatalogEntry) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a Connector").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            List {
                Section("Apps (sign in with your account)") {
                    ForEach(ConnectorCatalog.remoteEntries) { row($0) }
                }
                Section("On this Mac (local)") {
                    ForEach(ConnectorCatalog.localEntries) { row($0) }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 560, height: 520)
    }

    private func row(_ e: CatalogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.symbol)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.config.name).font(.system(size: 13, weight: .semibold))
                Text(e.summary).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Add") { onPick(e) }
        }
        .padding(.vertical, 3)
    }
}

struct ConnectorEditor: View {
    let request: EditorRequest
    let onSave: (ConnectorConfig) -> Void
    let onCancel: () -> Void

    @State private var config: ConnectorConfig
    @State private var argsText: String
    @State private var envText: String
    @State private var headersText: String

    init(request: EditorRequest, onSave: @escaping (ConnectorConfig) -> Void, onCancel: @escaping () -> Void) {
        self.request = request
        self.onSave = onSave
        self.onCancel = onCancel
        _config = State(initialValue: request.config)
        _argsText = State(initialValue: request.config.args.joined(separator: "\n"))
        _envText = State(initialValue: request.config.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _headersText = State(initialValue: request.config.headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    private var isValid: Bool {
        let nameOK = !config.name.trimmingCharacters(in: .whitespaces).isEmpty
        switch config.kind {
        case .remote: return nameOK && config.url.trimmingCharacters(in: .whitespaces).hasPrefix("http")
        case .local: return nameOK && !config.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew ? "Add Connector" : "Edit Connector")
                .font(.system(size: 17, weight: .semibold))
            if let note = request.note {
                Text(note)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeled("Name") {
                TextField("e.g. Linear", text: $config.name)
            }
            labeled("Type") {
                Picker("", selection: $config.kind) {
                    Text("Remote (URL)").tag(ConnectorConfig.Kind.remote)
                    Text("Local (runs on this Mac)").tag(ConnectorConfig.Kind.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if config.kind == .remote {
                labeled("Server URL") {
                    TextField("https://example.com/mcp", text: $config.url)
                }
                labeled("Headers (optional, one per line)") {
                    multiline($headersText, placeholder: "Authorization: Bearer <token>")
                }
            } else {
                labeled("Command") {
                    TextField("npx", text: $config.command)
                }
                labeled("Arguments (one per line)") {
                    multiline($argsText, placeholder: "-y\n@scope/some-mcp-server")
                }
                labeled("Environment (KEY=value, one per line)") {
                    multiline($envText, placeholder: "API_KEY=…")
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Add & Connect" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
        }
    }

    private func multiline(_ text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 64)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color.secondary.opacity(0.6))
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
    }

    private func save() {
        var c = config
        c.url = c.url.trimmingCharacters(in: .whitespacesAndNewlines)
        c.command = c.command.trimmingCharacters(in: .whitespacesAndNewlines)
        c.args = lines(argsText)
        c.env = pairs(envText, separator: "=")
        c.headers = pairs(headersText, separator: ":")
        if c.kind == .remote { c.command = ""; c.args = []; c.env = [:] } else { c.url = ""; c.headers = [:] }
        onSave(c)
    }

    private func lines(_ s: String) -> [String] {
        s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func pairs(_ s: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(s) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v }
        }
        return out
    }
}
