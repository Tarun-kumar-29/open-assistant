import Foundation

// A small Model Context Protocol client: JSON-RPC over stdio (local servers)
// or Streamable HTTP (remote servers).

struct MCPTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum MCPError: LocalizedError {
    case authRequired(wwwAuthenticate: String?)
    case sessionExpired
    case server(String)
    case transport(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .authRequired: return "Sign-in required."
        case .sessionExpired: return "The server session expired."
        case .server(let m): return m
        case .transport(let m): return m
        case .timeout: return "The server took too long to respond."
        }
    }
}

protocol MCPTransport {
    /// Sends a JSON-RPC request and returns its `result` object.
    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any]
    func notify(_ method: String, params: [String: Any]?) async throws
    func setProtocolVersion(_ version: String) async
    func close() async
}

enum JSONRPC {
    static func message(id: Int?, method: String, params: [String: Any]?) -> [String: Any] {
        var m: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { m["id"] = id }
        if let params { m["params"] = params }
        return m
    }

    /// Returns the result for a response object, or throws its error.
    static func result(from obj: [String: Any]) throws -> [String: Any] {
        if let err = obj["error"] as? [String: Any] {
            let msg = err["message"] as? String ?? "Unknown error"
            let code = err["code"] as? Int ?? 0
            throw MCPError.server("\(msg) (code \(code))")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    static func id(of obj: [String: Any]) -> Int? {
        if let i = obj["id"] as? Int { return i }
        if let s = obj["id"] as? String { return Int(s) }
        return nil
    }
}

// MARK: - stdio (local servers)

final class StdioTransport: MCPTransport {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var logHandle: FileHandle?
    private let lock = NSLock()
    /// All writes to the server go through one serial queue so messages never interleave.
    private let writeQueue = DispatchQueue(label: "openassistant.mcp.stdio.write")
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 1
    private var closed = false

    init(command: String, args: [String], env: [String: String], logURL: URL) throws {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { throw SimpleError("No command set for this connector.") }

        // Run through a login shell so PATH matches Terminal (Homebrew, npx, uvx…).
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin"
        let line = ([cmd] + args).map(Self.shellQuote).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Login shells skip ~/.zshrc, where nvm usually lives, so load nvm explicitly if present.
        let nvm = "[ -s \"$HOME/.nvm/nvm.sh\" ] && . \"$HOME/.nvm/nvm.sh\" >/dev/null 2>&1"
        process.arguments = ["-lc", "export PATH=\"$PATH:\(extraPath)\"; \(nvm); exec \(line)"]
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardError = logHandle ?? FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data)
        }
        process.terminationHandler = { [weak self] p in
            self?.markClosed()
            self?.failAll(MCPError.transport("The local server stopped (exit code \(p.terminationStatus)). Check its log for details."))
        }
        try process.run()
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = locked {
            defer { nextID += 1 }
            return nextID
        }
        var data = try JSONSerialization.data(withJSONObject: JSONRPC.message(id: id, method: method, params: params))
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: Any], Error>) in
            let isClosed: Bool = locked {
                if closed { return true }
                pending[id] = cont
                return false
            }
            if isClosed {
                cont.resume(throwing: MCPError.transport("The local server is not running."))
                return
            }
            // Arm the timeout first: a write to a server that stopped reading can block.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.fail(id: id, MCPError.timeout)
            }
            write(data) { [weak self] error in
                self?.fail(id: id, MCPError.transport("Could not talk to the local server: \(error.localizedDescription)"))
            }
        }
    }

    func notify(_ method: String, params: [String: Any]?) async throws {
        var data = try JSONSerialization.data(withJSONObject: JSONRPC.message(id: nil, method: method, params: params))
        data.append(0x0A)
        write(data, onError: nil)
    }

    private func write(_ data: Data, onError: ((Error) -> Void)?) {
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async {
            do {
                try handle.write(contentsOf: data)
            } catch {
                onError?(error)
            }
        }
    }

    func setProtocolVersion(_ version: String) async {}

    deinit {
        if process.isRunning { process.terminate() }
    }

    private func markClosed() { locked { closed = true } }

    func close() async {
        markClosed()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        failAll(MCPError.transport("Disconnected."))
        try? logHandle?.close()
    }

    // MARK: Internals

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func ingest(_ data: Data) {
        var lines: [Data] = []
        locked {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer.subdata(in: buffer.startIndex..<nl))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        for line in lines {
            guard !line.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        if let method = obj["method"] as? String {
            // A request from the server to us. Answer pings; politely refuse anything else.
            guard obj["id"] != nil else { return }   // notification: ignore
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": obj["id"]!]
            if method == "ping" {
                reply["result"] = [String: Any]()
            } else {
                reply["error"] = ["code": -32601, "message": "Method not supported by this client"]
            }
            if var d = try? JSONSerialization.data(withJSONObject: reply) {
                d.append(0x0A)
                write(d, onError: nil)
            }
            return
        }
        guard let id = JSONRPC.id(of: obj) else { return }
        let cont: CheckedContinuation<[String: Any], Error>? = locked { pending.removeValue(forKey: id) }
        guard let cont else { return }
        do {
            cont.resume(returning: try JSONRPC.result(from: obj))
        } catch {
            cont.resume(throwing: error)
        }
    }

    private func fail(id: Int, _ error: Error) {
        let cont: CheckedContinuation<[String: Any], Error>? = locked { pending.removeValue(forKey: id) }
        cont?.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let all: [CheckedContinuation<[String: Any], Error>] = locked {
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for c in all { c.resume(throwing: error) }
    }

    static func shellQuote(_ s: String) -> String {
        // Allow ~ expansion for paths like ~/Documents.
        if s.hasPrefix("~/") {
            return "~/" + shellQuote(String(s.dropFirst(2)))
        }
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Streamable HTTP (remote servers)

actor HTTPTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let tokenProvider: (@Sendable () async -> String?)?
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1

    init(url: URL, headers: [String: String], tokenProvider: (@Sendable () async -> String?)?) {
        self.url = url
        self.headers = headers
        self.tokenProvider = tokenProvider
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let response = try await post(JSONRPC.message(id: id, method: method, params: params), responseID: id, timeout: timeout)
        guard let response else { throw MCPError.transport("The server sent no response.") }
        return try JSONRPC.result(from: response)
    }

    func notify(_ method: String, params: [String: Any]?) async throws {
        _ = try await post(JSONRPC.message(id: nil, method: method, params: params), responseID: nil, timeout: 30)
    }

    func setProtocolVersion(_ version: String) async { protocolVersion = version }

    func close() async {
        guard let sid = sessionID else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "DELETE"
        req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id")
        await applyAuth(&req)
        _ = try? await URLSession.shared.data(for: req)
        sessionID = nil
    }

    private func applyAuth(_ req: inout URLRequest) async {
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let tokenProvider, let token = await tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func post(_ message: [String: Any], responseID: Int?, timeout: TimeInterval) async throws -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if let protocolVersion { req.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        await applyAuth(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MCPError.transport("No HTTP response.") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = sid }

        switch http.statusCode {
        case 401:
            throw MCPError.authRequired(wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"))
        case 404 where sessionID != nil && (message["method"] as? String) != "initialize":
            sessionID = nil
            throw MCPError.sessionExpired
        case 200..<300:
            break
        default:
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 4000 { break }
            }
            let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MCPError.transport("HTTP \(http.statusCode)\(body.isEmpty ? "" : ": \(body.prefix(300))")")
        }

        guard let responseID else { return nil }   // notifications get 202 Accepted

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            var pendingData = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                pendingData += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let d = pendingData.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: d) else { continue }
                pendingData = ""
                let objects = (parsed as? [[String: Any]]) ?? [(parsed as? [String: Any]) ?? [:]]
                for obj in objects where obj["method"] == nil && JSONRPC.id(of: obj) == responseID {
                    return obj
                }
            }
            throw MCPError.transport("The server closed the stream without answering.")
        } else {
            var data = Data()
            for try await b in bytes { data.append(b) }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw MCPError.transport("The server sent a response that isn't JSON.")
            }
            let objects = (parsed as? [[String: Any]]) ?? [(parsed as? [String: Any]) ?? [:]]
            return objects.first { JSONRPC.id(of: $0) == responseID } ?? objects.first
        }
    }
}

// MARK: - Client

final class MCPClient {
    let transport: MCPTransport
    static let protocolVersion = "2025-06-18"

    init(transport: MCPTransport) { self.transport = transport }

    func initialize() async throws {
        let result = try await transport.request("initialize", params: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Open Assistant", "version": "1.1"],
        ], timeout: 60)
        if let v = result["protocolVersion"] as? String { await transport.setProtocolVersion(v) }
        try await transport.notify("notifications/initialized", params: nil)
    }

    func listTools() async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await transport.request("tools/list", params: params, timeout: 60)
            for t in result["tools"] as? [[String: Any]] ?? [] {
                guard let name = t["name"] as? String else { continue }
                tools.append(MCPTool(
                    name: name,
                    description: t["description"] as? String ?? "",
                    inputSchema: t["inputSchema"] as? [String: Any] ?? ["type": "object"]
                ))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 500
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await transport.request("tools/call", params: ["name": name, "arguments": arguments], timeout: 180)
    }

    func close() async { await transport.close() }
}
