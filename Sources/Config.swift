import Foundation
import Security
import AppKit

/// Settings live in ~/Library/Application Support/OpenAssistant/config.json.
/// Any key missing from the file falls back to the default below.
struct AppConfig: Codable {
    var model: String = "claude-sonnet-5-5"
    var maxTokens: Int = 2048
    /// fn | rightOption | rightCommand | rightControl | keycode:<number> | none
    var hotkey: String = "fn"
    /// Hold to dictate into whatever app has the cursor. Same options as hotkey.
    var dictationHotkey: String = "rightOption"
    /// Tidy dictated text (punctuation, fillers) with a fast model before inserting it.
    var dictationCleanup: Bool = true
    var dictationModel: String = "claude-haiku-5-5"
    /// paste | accessibility | type — how dictated text is put into the focused app.
    var dictationInsert: String = "paste"
    /// always | activeOnly | never — when the floating pill is visible.
    var pillMode: String = "activeOnly"
    /// bottomCenter | bottomLeft | bottomRight | topCenter | topLeft | topRight | custom
    var pillPosition: String = "bottomCenter"
    /// Screen point of the pill's centre when pillPosition is "custom" (set by dragging it).
    var pillCustomX: Double = 0
    var pillCustomY: Double = 0
    var speechLocale: String = "en-IN"
    /// groq | apple — which engine produces the final transcript (Apple always gives the live preview).
    var transcriber: String = "groq"
    var groqModel: String = "whisper-large-v3-turbo"
    /// ISO-639-1 code to force a language, or "" for auto-detect.
    var transcribeLanguage: String = ""
    /// Style hint for Whisper: keeps Hinglish in Roman script and teaches it your vocabulary.
    var transcribePrompt: String = "Haan, kal 4 baje meeting hai. Please check the deployment on AWS. Add your own names and jargon here."
    var onDeviceRecognition: Bool = false
    /// Leave empty to auto-pick the best installed voice for speechLocale.
    var voiceIdentifier: String = ""
    var speechRate: Double = 0.52
    var speakReplies: Bool = true
    /// firstLine | all | none — how much of the answer is read aloud. The full answer is always shown on screen.
    var speakMode: String = "firstLine"
    var webSearch: Bool = true
    /// Ask before running AppleScript / shell commands.
    var confirmScripts: Bool = true
    var conversationResetMinutes: Double = 10
    var panelHideSeconds: Double = 14
    var userName: String = String(NSFullUserName().split(separator: " ").first ?? "")
    var extraInstructions: String = ""

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("OpenAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    /// User-visible folder for logs: ~/Documents/Open Assistant
    static var logDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let d = docs.appendingPathComponent("Open Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func load() -> AppConfig {
        let defaults = AppConfig()
        guard let data = try? Data(contentsOf: fileURL) else {
            defaults.save()
            return defaults
        }
        guard let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any]
        else {
            NSLog("OpenAssistant: config.json is not valid JSON; using defaults")
            return defaults
        }
        for (k, v) in user { merged[k] = v }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: mergedData)
        else {
            NSLog("OpenAssistant: config.json has a wrong value type; using defaults")
            return defaults
        }
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: AppConfig.fileURL) }
    }
}

enum Keychain {
    private static let service = "OpenAssistant"
    private static let apiKeyAccount = "anthropic_api_key"

    static func apiKey() -> String? {
        if let k = read(apiKeyAccount), !k.isEmpty { return k }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    static func setAPIKey(_ key: String) { write(apiKeyAccount, key) }

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes (or, with an empty value, deletes) a secret.
    static func write(_ account: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct SimpleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
