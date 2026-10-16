import Foundation

/// Minimal streaming client for the Anthropic Messages API.
@MainActor
final class ClaudeClient {
    struct Result {
        var content: [[String: Any]]
        var stopReason: String?
    }

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func stream(
        body: [String: Any],
        apiKey: String,
        betas: [String],
        onText: (String) -> Void,
        onBlockStart: ([String: Any]) -> Void
    ) async throws -> Result {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        var b = body
        b["stream"] = true
        req.httpBody = try JSONSerialization.data(withJSONObject: b)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw SimpleError("No response from the API.") }

        if http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 100_000 { break }
            }
            throw SimpleError("API error \(http.statusCode): \(Self.errorMessage(from: data))")
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let d = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                let idx = obj["index"] as? Int ?? blocks.count
                let block = obj["content_block"] as? [String: Any] ?? [:]
                blocks[idx] = block
                onBlockStart(block)

            case "content_block_delta":
                let idx = obj["index"] as? Int ?? 0
                guard let delta = obj["delta"] as? [String: Any] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let t = delta["text"] as? String ?? ""
                    let existing = blocks[idx]?["text"] as? String ?? ""
                    blocks[idx]?["text"] = existing + t
                    onText(t)
                case "input_json_delta":
                    partialJSON[idx, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    let existing = blocks[idx]?["thinking"] as? String ?? ""
                    blocks[idx]?["thinking"] = existing + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    blocks[idx]?["signature"] = delta["signature"] as? String ?? ""
                default:
                    break   // citations etc.
                }

            case "content_block_stop":
                let idx = obj["index"] as? Int ?? 0
                if let pj = partialJSON[idx], !pj.isEmpty,
                   let data = pj.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: data) {
                    blocks[idx]?["input"] = input
                }

            case "message_delta":
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String {
                    stopReason = sr
                }

            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Unknown streaming error"
                throw SimpleError("API error: \(msg)")

            default:
                break
            }
        }

        let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
        return Result(content: Self.sanitize(ordered), stopReason: stopReason)
    }

    /// Make assistant content safe to send back in the next request.
    private static func sanitize(_ blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.compactMap { block in
            var b = block
            switch b["type"] as? String {
            case "text":
                guard let t = b["text"] as? String,
                      !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                b.removeValue(forKey: "citations")
            case "thinking":
                // Only a complete, signed thinking block can be sent back; drop anything else.
                guard let t = b["thinking"] as? String, !t.isEmpty,
                      let sig = b["signature"] as? String, !sig.isEmpty else { return nil }
                b = ["type": "thinking", "thinking": t, "signature": sig]
            case "redacted_thinking":
                guard b["data"] != nil else { return nil }
            default:
                break
            }
            return b
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return msg
        }
        return String(decoding: data.prefix(500), as: UTF8.self)
    }
}
