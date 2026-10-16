import Cocoa

struct ConnectorConfig: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case remote, local }

    var id: String
    var name: String
    var kind: Kind
    var url: String = ""
    var command: String = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var headers: [String: String] = [:]
    var enabled: Bool = true

    init(id: String, name: String, kind: Kind, url: String = "", command: String = "", args: [String] = [],
         env: [String: String] = [:], headers: [String: String] = [:], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.enabled = enabled
    }

    /// Tolerates missing keys so a hand-edited file still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .remote
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var subtitle: String {
        switch kind {
        case .remote: return url
        case .local: return ([command] + args).joined(separator: " ")
        }
    }
}

struct CatalogEntry: Identifiable {
    var id: String { config.id }
    let config: ConnectorConfig
    let summary: String
    let symbol: String
    /// Shown in the editor when the entry needs something filled in.
    var note: String?
}

enum ConnectorCatalog {
    static func remote(_ id: String, _ name: String, _ url: String, _ summary: String, _ symbol: String,
                       headers: [String: String] = [:], note: String? = nil) -> CatalogEntry {
        CatalogEntry(config: ConnectorConfig(id: id, name: name, kind: .remote, url: url, headers: headers),
                     summary: summary, symbol: symbol, note: note)
    }

    static func local(_ id: String, _ name: String, _ command: String, _ args: [String], _ summary: String,
                      _ symbol: String, env: [String: String] = [:], note: String? = nil) -> CatalogEntry {
        CatalogEntry(config: ConnectorConfig(id: id, name: name, kind: .local, command: command, args: args, env: env),
                     summary: summary, symbol: symbol, note: note)
    }

    static let remoteEntries: [CatalogEntry] = [
        remote("linear", "Linear", "https://mcp.linear.app/mcp", "Issues, projects and cycles", "checklist"),
        remote("notion", "Notion", "https://mcp.notion.com/mcp", "Search, read and write pages and databases", "doc.text"),
        remote("atlassian", "Jira & Confluence", "https://mcp.atlassian.com/v1/mcp", "Jira issues and Confluence pages", "square.stack.3d.up"),
        remote("sentry", "Sentry", "https://mcp.sentry.dev/mcp", "Errors, issues and releases", "exclamationmark.triangle"),
        remote("github", "GitHub", "https://api.githubcopilot.com/mcp/", "Repos, issues and pull requests", "chevron.left.forwardslash.chevron.right",
               headers: ["Authorization": "Bearer YOUR_GITHUB_TOKEN"],
               note: "GitHub needs a personal access token: github.com → Settings → Developer settings → Personal access tokens. Paste it in place of YOUR_GITHUB_TOKEN."),
        remote("stripe", "Stripe", "https://mcp.stripe.com", "Payments, customers and invoices", "creditcard"),
        remote("supabase", "Supabase", "https://mcp.supabase.com/mcp", "Databases, tables and SQL", "cylinder"),
        remote("vercel", "Vercel", "https://mcp.vercel.com", "Projects and deployments", "triangle"),
        remote("huggingface", "Hugging Face", "https://huggingface.co/mcp", "Models, datasets and Spaces", "face.smiling"),
        remote("context7", "Context7", "https://mcp.context7.com/mcp", "Up-to-date docs for libraries (no sign-in)", "books.vertical"),
        remote("deepwiki", "DeepWiki", "https://mcp.deepwiki.com/mcp", "Ask about any public GitHub repo (no sign-in)", "text.book.closed"),
        remote("cloudflare-docs", "Cloudflare Docs", "https://docs.mcp.cloudflare.com/mcp", "Search Cloudflare documentation (no sign-in)", "cloud"),
        remote("zapier", "Zapier (Gmail, Calendar, Slack, 8000+ apps)", "https://mcp.zapier.com/api/mcp/mcp",
               "Connect almost any app through Zapier", "bolt",
               headers: ["Authorization": "Bearer PASTE_ZAPIER_MCP_TOKEN"],
               note: "Easiest way to get Gmail and Google Calendar without a Google Cloud project: go to mcp.zapier.com, create an MCP server, add the Gmail and Google Calendar actions you want, then copy its URL and token here. Free tier has a monthly call limit."),
    ]

    static let localEntries: [CatalogEntry] = [
        local("google", "Google: Gmail, Calendar, Meet, Drive", "uvx",
              ["workspace-mcp", "--tools", "gmail", "calendar", "drive"],
              "Read and send mail, manage events and Meet links, search Drive", "envelope",
              env: ["GOOGLE_OAUTH_CLIENT_ID": "PASTE_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET": "PASTE_CLIENT_SECRET"],
              note: "Needs a free Google Cloud OAuth client (5 min): console.cloud.google.com → create a project → enable the Gmail, Calendar and Drive APIs → OAuth consent screen (External, add yourself as a test user) → Credentials → Create OAuth client ID → Web application → add redirect URI http://localhost:8000/oauth2callback. Paste the client ID and secret below. The first time you ask it something, a browser tab opens to sign in. Needs uv (brew install uv)."),
        local("filesystem", "Files", "npx", ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"],
              "Read and write files in folders you choose", "folder",
              note: "Change ~/Documents to the folders it may use (one per line). Needs Node.js."),
        local("fetch", "Web Fetch", "uvx", ["mcp-server-fetch"], "Read any web page as text", "arrow.down.doc",
              note: "Needs uv (brew install uv)."),
        local("git", "Git", "uvx", ["mcp-server-git", "--repository", "~/code/my-repo"], "Git status, diffs, logs and commits", "arrow.triangle.branch",
              note: "Point --repository at your repo. Needs uv (brew install uv)."),
        local("playwright", "Browser (Playwright)", "npx", ["-y", "@playwright/mcp@latest"], "Drive a real browser: click, type, read pages", "safari",
              note: "Needs Node.js."),
        local("knowledge-graph", "Knowledge Graph Memory", "npx", ["-y", "@modelcontextprotocol/server-memory"], "A structured long-term memory graph", "brain",
              note: "Needs Node.js."),
        local("time", "Time Zones", "uvx", ["mcp-server-time"], "Time and time-zone conversions", "clock",
              note: "Needs uv (brew install uv)."),
    ]
}

/// Owns the user's connectors: saves them, keeps them connected, and exposes their tools to Claude.
@MainActor
final class ConnectorManager: ObservableObject {
    enum Status: Equatable {
        case off, connecting, connected, needsLogin
        case error(String)
    }

    struct Runtime {
        var status: Status = .off
        var tools: [MCPTool] = []
    }

    @Published private(set) var connectors: [ConnectorConfig] = []
    @Published private(set) var runtime: [String: Runtime] = [:]

    private var clients: [String: MCPClient] = [:]
    private var authHints: [String: String] = [:]
    private var toolIndex: [String: (connector: String, tool: String)] = [:]
    private var definitions: [[String: Any]] = []
    /// Bumped on every connect/disable/remove so a slow, stale connect attempt can't win.
    private var generation: [String: Int] = [:]

    static var fileURL: URL { AppConfig.dir.appendingPathComponent("connectors.json") }
    static var logDir: URL {
        let d = AppConfig.dir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        if let list = try? JSONDecoder().decode([ConnectorConfig].self, from: data) {
            connectors = list
        } else {
            // Don't let the next save overwrite a file we couldn't read.
            let backup = Self.fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: Self.fileURL, to: backup)
            NSLog("OpenAssistant: connectors.json couldn't be read; moved it to connectors.json.bad")
        }
    }

    // MARK: - For the assistant

    var toolDefinitions: [[String: Any]] { definitions }

    var connectedNames: [String] {
        connectors.filter { runtime[$0.id]?.status == .connected }.map(\.name)
    }

    func owns(_ toolName: String) -> Bool { toolIndex[toolName] != nil }

    func label(for toolName: String) -> String? {
        guard let entry = toolIndex[toolName],
              let c = connectors.first(where: { $0.id == entry.connector }) else { return nil }
        return "\(c.name): \(entry.tool.replacingOccurrences(of: "_", with: " "))…"
    }

    func call(_ toolName: String, input: [String: Any]) async -> ToolOutput {
        guard let entry = toolIndex[toolName] else { return .error("Unknown connector tool \(toolName).") }
        return await call(connector: entry.connector, tool: entry.tool, input: input, retry: true)
    }

    private func call(connector id: String, tool: String, input: [String: Any], retry: Bool) async -> ToolOutput {
        guard let client = clients[id] else {
            return .error("That connector isn't connected right now. Ask the user to check Connectors.")
        }
        do {
            let result = try await client.callTool(name: tool, arguments: input)
            return Self.convert(result)
        } catch MCPError.authRequired(let hint) {
            if retry, TokenStore.load(id: id)?.refreshToken != nil, await TokenStore.forceRefresh(id: id) {
                return await call(connector: id, tool: tool, input: input, retry: false)
            }
            authHints[id] = hint
            setStatus(id, .needsLogin)
            return .error("The sign-in for this connector expired. Ask the user to log in again from Connectors.")
        } catch MCPError.sessionExpired where retry {
            if let c = config(id) { await connectNow(c) }
            return await call(connector: id, tool: tool, input: input, retry: false)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// MCP tool result → Claude tool_result content.
    private static func convert(_ result: [String: Any]) -> ToolOutput {
        var blocks: [[String: Any]] = []
        var texts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text":
                let t = item["text"] as? String ?? ""
                texts.append(t)
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(["type": "text", "text": t])
                }
            case "image":
                let mime = item["mimeType"] as? String ?? ""
                if ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime),
                   let data = item["data"] as? String {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": mime, "data": data]])
                }
            case "resource":
                if let r = item["resource"] as? [String: Any], let t = r["text"] as? String {
                    texts.append(t)
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(["type": "text", "text": t])
                    }
                }
            default:
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let s = String(data: d, encoding: .utf8) {
                    texts.append(s)
                    blocks.append(["type": "text", "text": s])
                }
            }
        }
        if blocks.isEmpty, let structured = result["structuredContent"],
           let d = try? JSONSerialization.data(withJSONObject: structured),
           let s = String(data: d, encoding: .utf8) {
            texts.append(s)
        }
        let joined = ToolRunner.truncate(texts.joined(separator: "\n"), limit: 20_000)
        if (result["isError"] as? Bool) == true { return .error(joined.isEmpty ? "The tool reported an error." : joined) }
        let hasImage = blocks.contains { ($0["type"] as? String) == "image" }
        return hasImage ? .content(blocks) : .text(joined)
    }

    // MARK: - Lifecycle

    func startAll() {
        for c in connectors where c.enabled { connect(c.id) }
    }

    func connect(_ id: String) {
        guard let c = config(id) else { return }
        Task { await self.connectNow(c) }
    }

    private func connectNow(_ c: ConnectorConfig, allowRefresh: Bool = true) async {
        let myGen = (generation[c.id] ?? 0) + 1
        generation[c.id] = myGen
        let isCurrent = { [weak self] in self?.generation[c.id] == myGen }
        await dropClient(c.id)
        guard isCurrent() else { return }
        setStatus(c.id, .connecting)
        do {
            let transport: MCPTransport
            switch c.kind {
            case .local:
                transport = try StdioTransport(command: c.command, args: c.args, env: c.env, logURL: logURL(c.id))
            case .remote:
                guard let url = URL(string: c.url.trimmingCharacters(in: .whitespaces)),
                      url.scheme == "https" || url.host == "localhost" || url.host == "127.0.0.1" else {
                    throw SimpleError("Enter a full https:// URL.")
                }
                let id = c.id
                transport = HTTPTransport(url: url, headers: c.headers,
                                          tokenProvider: { await TokenStore.validAccessToken(id: id) })
            }
            let client = MCPClient(transport: transport)
            do {
                try await client.initialize()
                let tools = try await client.listTools()
                // The user may have edited, switched off or removed it while we were connecting.
                guard isCurrent(), let current = config(c.id), current.enabled, current == c else {
                    await client.close()
                    return
                }
                let old = clients.updateValue(client, forKey: c.id)
                runtime[c.id] = Runtime(status: .connected, tools: tools)
                rebuildTools()
                await old?.close()
            } catch {
                await client.close()
                throw error
            }
        } catch MCPError.authRequired(let hint) {
            guard isCurrent() else { return }
            if allowRefresh, TokenStore.load(id: c.id)?.refreshToken != nil, await TokenStore.forceRefresh(id: c.id) {
                await connectNow(c, allowRefresh: false)
                return
            }
            guard isCurrent() else { return }
            authHints[c.id] = hint
            setStatus(c.id, .needsLogin)
        } catch {
            guard isCurrent() else { return }
            setStatus(c.id, .error(error.localizedDescription))
        }
    }

    func login(_ id: String) {
        guard let c = config(id), let url = URL(string: c.url) else { return }
        setStatus(id, .connecting)
        let hint = authHints[id]
        Task {
            do {
                let tokens = try await OAuth.authorize(serverURL: url, wwwAuthenticate: hint)
                TokenStore.save(tokens, id: id)
                await self.connectNow(c)
            } catch {
                self.setStatus(id, .error("Sign-in failed: \(error.localizedDescription)"))
            }
        }
    }

    func logout(_ id: String) {
        generation[id, default: 0] += 1
        TokenStore.delete(id: id)
        Task {
            await self.dropClient(id)
            self.setStatus(id, .needsLogin)
        }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let i = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[i].enabled = on
        save()
        if on {
            connect(id)
        } else {
            generation[id, default: 0] += 1
            Task {
                await self.dropClient(id)
                self.runtime[id] = Runtime()
            }
        }
    }

    /// Adds a new connector (giving it a unique id) or updates an existing one, then (re)connects.
    func upsert(_ config: ConnectorConfig, isNew: Bool) {
        var c = config
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        if isNew {
            c.id = uniqueID(for: c.name)
            connectors.append(c)
        } else if let i = connectors.firstIndex(where: { $0.id == c.id }) {
            connectors[i] = c
        }
        save()
        if c.enabled { connect(c.id) }
    }

    func remove(_ id: String) {
        generation[id, default: 0] += 1
        connectors.removeAll { $0.id == id }
        save()
        TokenStore.delete(id: id)
        Task {
            await self.dropClient(id)
            self.runtime[id] = nil
        }
    }

    func logURL(_ id: String) -> URL { Self.logDir.appendingPathComponent("\(id).log") }

    // MARK: - Internals

    private func config(_ id: String) -> ConnectorConfig? { connectors.first { $0.id == id } }

    private func setStatus(_ id: String, _ status: Status) {
        var r = runtime[id] ?? Runtime()
        r.status = status
        if status != .connected { r.tools = [] }
        runtime[id] = r
        if status != .connected { rebuildTools() }
    }

    private func dropClient(_ id: String) async {
        if let client = clients.removeValue(forKey: id) {
            rebuildTools()
            await client.close()
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(connectors) else { return }
        try? d.write(to: Self.fileURL, options: .atomic)
        // May contain API tokens in headers: owner-only permissions.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    private func uniqueID(for name: String) -> String {
        var base = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        base = base.split(separator: "-").joined(separator: "-")
        if base.isEmpty { base = "connector" }
        base = String(base.prefix(24))
        var id = base
        var n = 2
        while connectors.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Claude tool names must match ^[a-zA-Z0-9_-]{1,64}$ and be unique.
    private func rebuildTools() {
        toolIndex = [:]
        definitions = []
        for c in connectors {
            guard clients[c.id] != nil, let tools = runtime[c.id]?.tools else { continue }
            var prefix = String(c.id.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined().prefix(20))
            if prefix.isEmpty { prefix = "app" }
            for t in tools {
                let safe = t.name.map {
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? String($0) : "_"
                }.joined()
                var name = String("\(prefix)__\(safe)".prefix(64))
                var n = 2
                while toolIndex[name] != nil {
                    let suffix = "_\(n)"
                    name = String("\(prefix)__\(safe)".prefix(64 - suffix.count)) + suffix
                    n += 1
                }
                toolIndex[name] = (c.id, t.name)
                var schema = t.inputSchema
                schema.removeValue(forKey: "$schema")
                if schema["type"] == nil { schema["type"] = "object" }
                let desc = t.description.isEmpty ? t.name : t.description
                definitions.append([
                    "name": name,
                    "description": "[\(c.name)] " + String(desc.prefix(1000)),
                    "input_schema": schema,
                ])
            }
        }
    }
}
