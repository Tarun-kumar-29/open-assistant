import Foundation

/// Streams chat completions from any OpenAI-compatible API (OpenAI, Groq, OpenRouter, …)
/// while speaking the assistant's internal Anthropic-style message format, so the rest of
/// the app doesn't care which provider is behind it.
@MainActor
final class OpenAIClient {
    func stream(
        baseURL: URL,
        apiKey: String,
        model: String,
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        maxTokens: Int,
        useMaxCompletionTokens: Bool,
        onText: (String) -> Void,
        onBlockStart: ([String: Any]) -> Void
    ) async throws -> ClaudeClient.Result {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system]] + Self.convertMessages(messages),
            "stream": true,
        ]
        body[useMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] = maxTokens
        let fnTools = Self.convertTools(tools)
        if !fnTools.isEmpty { body["tools"] = fnTools }

        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if baseURL.host?.contains("openrouter") == true {
            req.setValue("https://github.com/Tarun-kumar-29/open-assistant", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Open Assistant", forHTTPHeaderField: "X-Title")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw SimpleError("No response from the API.") }
        if http.statusCode != 200 {
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count > 100_000 { break }
            }
            throw SimpleError("API error \(http.statusCode): \(Self.errorMessage(from: data))")
        }

        var text = ""
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var announced: Set<Int> = []
        var finish: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw SimpleError("API error: \(err["message"] as? String ?? "unknown")")
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let fr = choice["finish_reason"] as? String { finish = fr }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let t = delta["content"] as? String, !t.isEmpty {
                text += t
                onText(t)
            }
            for tc in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let idx = tc["index"] as? Int ?? 0
                var entry = calls[idx] ?? (id: "", name: "", args: "")
                if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                if let fn = tc["function"] as? [String: Any] {
                    if let n = fn["name"] as? String, !n.isEmpty { entry.name += n }
                    if let a = fn["arguments"] as? String { entry.args += a }
                }
                calls[idx] = entry
                if !announced.contains(idx), !entry.name.isEmpty {
                    announced.insert(idx)
                    onBlockStart(["type": "tool_use", "name": entry.name])
                }
            }
        }

        var content: [[String: Any]] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "text", "text": text])
        }
        for idx in calls.keys.sorted() {
            let c = calls[idx]!
            let input = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) as? [String: Any] ?? [:]
            content.append([
                "type": "tool_use",
                "id": c.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : c.id,
                "name": c.name,
                "input": input,
            ])
        }
        let stop: String
        switch finish {
        case "tool_calls", "function_call": stop = "tool_use"
        case "length": stop = "max_tokens"
        default: stop = calls.isEmpty ? "end_turn" : "tool_use"
        }
        return ClaudeClient.Result(content: content, stopReason: stop)
    }

    // MARK: - Format conversion

    /// Anthropic tool definitions → OpenAI function tools. Server-side tools (web search) are dropped.
    static func convertTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { t in
            guard let name = t["name"] as? String, let schema = t["input_schema"] else { return nil }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": t["description"] as? String ?? "",
                    "parameters": schema,
                ],
            ]
        }
    }

    /// Anthropic-style history → OpenAI messages.
    static func convertMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in messages {
            let role = m["role"] as? String ?? "user"
            if let s = m["content"] as? String {
                out.append(["role": role, "content": s])
                continue
            }
            let blocks = m["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                var text = ""
                var toolCalls: [[String: Any]] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        text += b["text"] as? String ?? ""
                    case "tool_use":
                        let inputObj: Any = b["input"] ?? [String: Any]()
                        let args = (try? JSONSerialization.data(withJSONObject: inputObj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.append([
                            "id": b["id"] as? String ?? "",
                            "type": "function",
                            "function": ["name": b["name"] as? String ?? "", "arguments": args],
                        ])
                    default:
                        break   // thinking etc.
                    }
                }
                var msg: [String: Any] = ["role": "assistant"]
                msg["content"] = text.isEmpty ? (NSNull() as Any) : (text as Any)
                if !toolCalls.isEmpty { msg["tool_calls"] = toolCalls }
                if text.isEmpty && toolCalls.isEmpty { continue }
                out.append(msg)
            } else {
                var userParts: [[String: Any]] = []
                var images: [[String: Any]] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        userParts.append(["type": "text", "text": b["text"] as? String ?? ""])
                    case "tool_result":
                        let (resultText, resultImages) = flattenToolResult(b["content"])
                        out.append([
                            "role": "tool",
                            "tool_call_id": b["tool_use_id"] as? String ?? "",
                            "content": resultText.isEmpty ? "(done)" : resultText,
                        ])
                        images += resultImages
                    case "image":
                        if let img = imagePart(b) { images.append(img) }
                    default:
                        break
                    }
                }
                if !images.isEmpty {
                    userParts.append(["type": "text", "text": "Screenshot from the tool above:"])
                    userParts += images
                }
                if !userParts.isEmpty {
                    out.append(["role": "user", "content": userParts])
                }
            }
        }
        return out
    }

    private static func flattenToolResult(_ content: Any?) -> (String, [[String: Any]]) {
        if let s = content as? String { return (s, []) }
        var text: [String] = []
        var images: [[String: Any]] = []
        for b in content as? [[String: Any]] ?? [] {
            switch b["type"] as? String {
            case "text": text.append(b["text"] as? String ?? "")
            case "image":
                if let img = imagePart(b) { images.append(img) }
                text.append("[screenshot attached]")
            default: break
            }
        }
        return (text.joined(separator: "\n"), images)
    }

    private static func imagePart(_ b: [String: Any]) -> [String: Any]? {
        guard let src = b["source"] as? [String: Any],
              let data = src["data"] as? String,
              let mime = src["media_type"] as? String else { return nil }
        return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data)"]]
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
            if let msg = obj["message"] as? String { return msg }
        }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }
}
