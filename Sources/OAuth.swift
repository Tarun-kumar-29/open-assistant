import Cocoa
import CryptoKit
import Network

/// Saved sign-in for one remote connector (kept in the Keychain).
struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientID: String
    var clientSecret: String?
    var resource: String
}

enum TokenStore {
    private static func account(_ id: String) -> String { "connector.\(id).oauth" }

    static func load(id: String) -> OAuthTokens? {
        guard let s = Keychain.read(account(id)), let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OAuthTokens.self, from: d)
    }

    static func save(_ tokens: OAuthTokens, id: String) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(tokens) else { return }
        Keychain.write(account(id), String(decoding: d, as: UTF8.self))
    }

    static func delete(id: String) { Keychain.write(account(id), "") }

    /// A usable access token, refreshing it first if it's about to expire. Nil if not signed in.
    static func validAccessToken(id: String) async -> String? {
        await TokenRefresher.shared.token(id: id, force: false)
    }

    /// Refresh now (e.g. after the server rejected the token). True if a fresh token was obtained.
    static func forceRefresh(id: String) async -> Bool {
        await TokenRefresher.shared.token(id: id, force: true) != nil
    }
}

struct OAuthError: LocalizedError {
    let code: String?
    let message: String
    var errorDescription: String? { message }
}

/// Serialises refreshes per connector, so a rotating refresh token is never used twice at once.
actor TokenRefresher {
    static let shared = TokenRefresher()
    private var inflight: [String: Task<String?, Never>] = [:]

    func token(id: String, force: Bool) async -> String? {
        if let running = inflight[id] { return await running.value }
        guard let stored = TokenStore.load(id: id) else { return nil }
        let expiring = stored.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        guard force || expiring else { return stored.accessToken }
        guard stored.refreshToken != nil else { return force ? nil : stored.accessToken }

        let task = Task<String?, Never> {
            do {
                let fresh = try await OAuth.refresh(stored)
                TokenStore.save(fresh, id: id)
                return fresh.accessToken
            } catch let e as OAuthError where ["invalid_grant", "invalid_client", "unauthorized_client"].contains(e.code ?? "") {
                TokenStore.delete(id: id)   // the sign-in is really dead
                return nil
            } catch {
                // Offline or a server hiccup: keep the saved sign-in and try again later.
                return force ? nil : stored.accessToken
            }
        }
        inflight[id] = task
        let result = await task.value
        inflight[id] = nil
        return result
    }
}

/// OAuth 2.1 sign-in as described by the MCP authorization spec:
/// protected-resource metadata → authorization-server metadata → dynamic client registration
/// → PKCE authorization code flow in the browser with a loopback redirect → tokens.
enum OAuth {

    static func authorize(serverURL: URL, wwwAuthenticate: String?) async throws -> OAuthTokens {
        let resource = canonical(serverURL)

        // 1. Where is the authorization server?
        let resourceMeta = await fetchResourceMetadata(serverURL: serverURL, wwwAuthenticate: wwwAuthenticate)
        let authServer = (resourceMeta?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:))
            ?? origin(of: serverURL)
        let scopes = resourceMeta?["scopes_supported"] as? [String] ?? []

        // 2. Its endpoints.
        let asMeta = await fetchAuthServerMetadata(authServer) ?? [:]
        let base = origin(of: authServer)
        let authEndpoint = (asMeta["authorization_endpoint"] as? String).flatMap(URL.init(string:))
            ?? base.appendingPathComponent("authorize")
        let tokenEndpoint = (asMeta["token_endpoint"] as? String).flatMap(URL.init(string:))
            ?? base.appendingPathComponent("token")
        let registrationEndpoint = (asMeta["registration_endpoint"] as? String).flatMap(URL.init(string:))
            ?? base.appendingPathComponent("register")

        // 3. Open a one-off local callback on a free port, then register this app as a client for it.
        let listener = try LoopbackListener()
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let registration: (String, String?)
        do {
            registration = try await register(at: registrationEndpoint, redirectURI: redirectURI)
        } catch {
            listener.stop()
            throw error
        }
        let clientID = registration.0
        let clientSecret = registration.1

        // 4. Browser sign-in with PKCE.
        let verifier = randomString(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(24)

        guard var comps = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false) else {
            listener.stop()
            throw SimpleError("Bad authorization URL.")
        }
        var items = comps.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource),
        ]
        if !scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " "))) }
        comps.queryItems = items
        guard let browserURL = comps.url else {
            listener.stop()
            throw SimpleError("Bad authorization URL.")
        }

        _ = await MainActor.run { NSWorkspace.shared.open(browserURL) }
        let params = try await listener.waitForCallback(timeout: 300)

        if let err = params["error"] {
            throw SimpleError("The service said: \(params["error_description"] ?? err)")
        }
        guard params["state"] == state else { throw SimpleError("Sign-in response didn't match (state mismatch).") }
        guard let code = params["code"], !code.isEmpty else { throw SimpleError("No authorization code was returned.") }

        // 5. Exchange the code for tokens.
        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": resource,
        ]
        if let clientSecret { form["client_secret"] = clientSecret }
        let tok = try await tokenRequest(tokenEndpoint, form: form)
        return OAuthTokens(
            accessToken: tok.access,
            refreshToken: tok.refresh,
            expiresAt: tok.expiresAt,
            tokenEndpoint: tokenEndpoint.absoluteString,
            clientID: clientID,
            clientSecret: clientSecret,
            resource: resource
        )
    }

    static func refresh(_ t: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = t.refreshToken, let endpoint = URL(string: t.tokenEndpoint) else {
            throw SimpleError("Can't refresh this sign-in.")
        }
        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": t.clientID,
            "resource": t.resource,
        ]
        if let s = t.clientSecret { form["client_secret"] = s }
        let tok = try await tokenRequest(endpoint, form: form)
        var updated = t
        updated.accessToken = tok.access
        updated.refreshToken = tok.refresh ?? t.refreshToken   // servers may rotate it
        updated.expiresAt = tok.expiresAt
        return updated
    }

    // MARK: - Discovery

    private static func fetchResourceMetadata(serverURL: URL, wwwAuthenticate: String?) async -> [String: Any]? {
        var candidates: [URL] = []
        if let header = wwwAuthenticate,
           let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) {
            let match = String(header[range])
            let value = match.replacingOccurrences(of: "resource_metadata=", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let u = URL(string: value) { candidates.append(u) }
        }
        let o = origin(of: serverURL).absoluteString
        let path = serverURL.path
        if !path.isEmpty && path != "/" {
            if let u = URL(string: o + "/.well-known/oauth-protected-resource" + path) { candidates.append(u) }
        }
        if let u = URL(string: o + "/.well-known/oauth-protected-resource") { candidates.append(u) }

        for u in candidates {
            if let json = await getJSON(u), json["authorization_servers"] != nil { return json }
        }
        return nil
    }

    private static func fetchAuthServerMetadata(_ issuer: URL) async -> [String: Any]? {
        let o = origin(of: issuer).absoluteString
        var path = issuer.path
        if path == "/" { path = "" }
        var candidates = [
            o + "/.well-known/oauth-authorization-server" + path,
            o + "/.well-known/openid-configuration" + path,
        ]
        if !path.isEmpty {
            candidates.append(o + path + "/.well-known/openid-configuration")
            candidates.append(o + "/.well-known/oauth-authorization-server")
        }
        for c in candidates {
            if let u = URL(string: c), let json = await getJSON(u), json["token_endpoint"] != nil { return json }
        }
        return nil
    }

    private static func register(at endpoint: URL, redirectURI: String) async throws -> (String, String?) {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_name": "Open Assistant",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clientID = json["client_id"] as? String else {
            throw SimpleError("This service doesn't support automatic sign-in (no client registration, HTTP \(status)). Edit the connector and add an API token header instead.")
        }
        return (clientID, json["client_secret"] as? String)
    }

    private static func tokenRequest(_ endpoint: URL, form: [String: String]) async throws
        -> (access: String, refresh: String?, expiresAt: Date?) {
        var req = URLRequest(url: endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(formEncode(form).utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let access = json["access_token"] as? String else {
            let msg = json["error_description"] as? String ?? json["error"] as? String ?? "HTTP \(status)"
            throw OAuthError(code: json["error"] as? String, message: "Token request failed: \(msg)")
        }
        var expiresAt: Date?
        if let n = json["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(n)
        } else if let s = json["expires_in"] as? String, let n = Double(s) {
            expiresAt = Date().addingTimeInterval(n)
        }
        return (access, json["refresh_token"] as? String, expiresAt)
    }

    private static func getJSON(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(MCPClient.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
    }

    // MARK: - Helpers

    static func origin(of url: URL) -> URL {
        var c = URLComponents()
        c.scheme = url.scheme
        c.host = url.host
        c.port = url.port
        return c.url ?? url
    }

    /// The server URL without fragment or trailing slash, as RFC 8707 expects.
    static func canonical(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        var s = c.url?.absoluteString ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(rng.next(upperBound: UInt32(chars.count)))] })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}

/// Tiny one-shot HTTP server on 127.0.0.1 that catches the OAuth redirect.
final class LoopbackListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "openassistant.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    private var finished = false

    private var readyContinuation: CheckedContinuation<UInt16, Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    /// Starts listening on a free port and returns it. Call before opening the browser.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async {
                self.readyContinuation = cont
                self.listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let c = self.readyContinuation {
                            self.readyContinuation = nil
                            if let port = self.listener.port?.rawValue {
                                c.resume(returning: port)
                            } else {
                                c.resume(throwing: SimpleError("Couldn't open a local sign-in callback."))
                            }
                        }
                    case .failed(let error):
                        let err = SimpleError("Couldn't open a local sign-in callback: \(error.localizedDescription)")
                        if let c = self.readyContinuation {
                            self.readyContinuation = nil
                            c.resume(throwing: err)
                        }
                        self.finish(.failure(err))
                    default:
                        break
                    }
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String: String], Error>) in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                    return
                }
                self.continuation = cont
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(SimpleError("Sign-in timed out.")))
                }
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2,
               let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
               comps.path == "/callback" {
                var params: [String: String] = [:]
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
                let ok = params["code"] != nil
                self.respond(conn, status: "200 OK", message: ok
                    ? "Signed in. You can close this tab and go back to Open Assistant."
                    : "Sign-in didn't complete. You can close this tab.")
                self.finish(.success(params))
            } else {
                self.respond(conn, status: "404 Not Found", message: "Not found")
            }
        }
    }

    private func respond(_ conn: NWConnection, status: String, message: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>Open Assistant</title></head>
        <body style="font-family:-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;height:90vh">
        <p style="font-size:18px">\(message)</p></body></html>
        """
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Always called on `queue`.
    private func finish(_ outcome: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let continuation {
            continuation.resume(with: outcome)
            self.continuation = nil
        } else {
            result = outcome   // arrived before anyone was waiting
        }
    }
}
