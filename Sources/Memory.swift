import Foundation

/// Long-term memory: a plain Markdown list you can edit by hand.
/// ~/Library/Application Support/OpenAssistant/memory.md
enum Memory {
    static var fileURL: URL { AppConfig.dir.appendingPathComponent("memory.md") }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func add(_ fact: String) {
        let clean = fact.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var text = read()
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "- \(clean)\n"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Removes every line containing `match` (case-insensitive). Returns how many were removed.
    static func forget(_ match: String) -> Int {
        let needle = match.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        let lines = read().components(separatedBy: "\n")
        let kept = lines.filter { !$0.lowercased().contains(needle) }
        let removed = lines.count - kept.count
        if removed > 0 {
            try? kept.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return removed
    }
}
