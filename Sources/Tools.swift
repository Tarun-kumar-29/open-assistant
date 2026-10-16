import Cocoa

enum ToolOutput {
    case text(String)
    case content([[String: Any]])
    case error(String)

    func asResult(id: String) -> [String: Any] {
        switch self {
        case .text(let s):
            return ["type": "tool_result", "tool_use_id": id, "content": s.isEmpty ? "(done, no output)" : s]
        case .content(let c):
            return ["type": "tool_result", "tool_use_id": id, "content": c]
        case .error(let s):
            return ["type": "tool_result", "tool_use_id": id, "content": s, "is_error": true]
        }
    }
}

/// Tools the assistant can use on this Mac.
@MainActor
final class ToolRunner {
    static let definitions: [[String: Any]] = [
        tool("open_app",
             "Open or switch to a macOS application by name, e.g. 'Safari', 'Slack', 'Visual Studio Code', 'Spotify'.",
             ["name": str("Application name")], ["name"]),
        tool("open_url",
             "Open a web link in the default browser, or an absolute file/folder path in its default app.",
             ["url": str("https:// URL or absolute file path")], ["url"]),
        tool("run_applescript",
             "Run AppleScript to automate Mac apps: Music/Spotify playback, Finder, Calendar, Reminders, Notes, Mail, System Events, volume, dark mode, etc. Returns the script result. The user may be asked to approve it first.",
             ["script": str("AppleScript source code")], ["script"]),
        tool("run_shell",
             "Run a zsh command on the Mac and return its output (60s limit). Use only when no simpler tool fits. The user may be asked to approve it first.",
             ["command": str("Shell command")], ["command"]),
        tool("type_text",
             "Type text into whatever field is focused in the frontmost app, as if typed on the keyboard.",
             ["text": str("Text to type")], ["text"]),
        tool("get_clipboard", "Read the current clipboard text.", [:], []),
        tool("set_clipboard", "Copy text to the clipboard.", ["text": str("Text to copy")], ["text"]),
        tool("take_screenshot",
             "Capture the main screen so you can see what the user is looking at. Use when they say 'this', 'on my screen', etc.",
             [:], []),
        tool("remember",
             "Save one durable fact or preference about the user to long-term memory (e.g. names, preferences, recurring tasks).",
             ["fact": str("One short fact, written in third person")], ["fact"]),
        tool("forget",
             "Delete long-term memory lines that contain the given text.",
             ["text": str("Text to match")], ["text"]),
    ]

    nonisolated private static func str(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    nonisolated private static func tool(_ name: String, _ description: String,
                             _ props: [String: Any], _ required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": ["type": "object", "properties": props, "required": required],
        ]
    }

    static func friendlyName(_ tool: String) -> String {
        switch tool {
        case "open_app": return "Opening app…"
        case "open_url": return "Opening link…"
        case "run_applescript": return "Running AppleScript…"
        case "run_shell": return "Running command…"
        case "type_text": return "Typing…"
        case "get_clipboard", "set_clipboard": return "Clipboard…"
        case "take_screenshot": return "Looking at your screen…"
        case "remember": return "Remembering…"
        case "forget": return "Forgetting…"
        case "web_search": return "Searching the web…"
        default: return "Using \(tool)…"
        }
    }

    func execute(name: String, input: [String: Any], confirmScripts: Bool) async -> ToolOutput {
        let s = { (key: String) -> String in (input[key] as? String) ?? "" }

        switch name {
        case "open_app":
            let app = s("name")
            let (code, out) = await runProcess("/usr/bin/open", ["-a", app], timeout: 15)
            return code == 0 ? .text("Opened \(app).") : .error("Could not open \(app): \(out)")

        case "open_url":
            let raw = s("url")
            let url: URL? = raw.hasPrefix("/") || raw.hasPrefix("~")
                ? URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                : URL(string: raw)
            guard let url, NSWorkspace.shared.open(url) else { return .error("Could not open \(raw)") }
            return .text("Opened \(raw).")

        case "run_applescript":
            let script = s("script")
            if confirmScripts, !confirm(title: "Run this AppleScript?", detail: script) {
                return .error("The user declined to run this script.")
            }
            let (code, out) = await runProcess("/usr/bin/osascript", ["-"], stdin: script, timeout: 30)
            return code == 0 ? .text(Self.truncate(out)) : .error("AppleScript failed: \(Self.truncate(out))")

        case "run_shell":
            let cmd = s("command")
            if confirmScripts, !confirm(title: "Run this shell command?", detail: cmd) {
                return .error("The user declined to run this command.")
            }
            let (code, out) = await runProcess("/bin/zsh", ["-lc", cmd], timeout: 60)
            return .text("exit code \(code)\n\(Self.truncate(out))")

        case "type_text":
            typeText(s("text"))
            return .text("Typed.")

        case "get_clipboard":
            return .text(NSPasteboard.general.string(forType: .string) ?? "(clipboard is empty)")

        case "set_clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s("text"), forType: .string)
            return .text("Copied to clipboard.")

        case "take_screenshot":
            return await screenshot()

        case "remember":
            Memory.add(s("fact"))
            return .text("Saved to memory.")

        case "forget":
            let n = Memory.forget(s("text"))
            return .text(n == 0 ? "Nothing matched in memory." : "Removed \(n) memory line(s).")

        default:
            return .error("Unknown tool \(name)")
        }
    }

    // MARK: - Helpers

    private func confirm(title: String, detail: String) -> Bool {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(detail.prefix(1500))
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let ok = alert.runModal() == .alertFirstButtonReturn
        previous?.activate(options: [])
        return ok
    }

    /// Append a line to ~/Documents/Open Assistant/dictation.log
    static func log(_ line: String) {
        let url = AppConfig.logDir.appendingPathComponent("dictation.log")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = "[\(f.string(from: Date()))] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Put text where the cursor is in the frontmost app.
    /// method: "auto"/"paste" (⌘V, works everywhere), "accessibility" (AX insert, then paste), or "type" (keystrokes).
    /// Returns a description of what was done, for the log.
    @discardableResult
    static func insertText(_ text: String, method: String = "auto") -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let trusted = AXIsProcessTrusted()
        var note = "front=\(front) ax=\(trusted) chars=\(text.count) method=\(method): "

        if method == "type" {
            typeUnicode(text)
            note += "typed"
            log(note)
            return note
        }
        if method == "accessibility", trusted, insertViaAccessibility(text) {
            note += "accessibility insert ok"
            log(note)
            return note
        }
        let pasted = pasteViaClipboard(text)
        note += pasted ? "pasted with ⌘V" : "paste failed → typed"
        if !pasted { typeUnicode(text) }
        log(note)
        return note
    }

    /// Native text fields expose their selection; replacing it inserts at the cursor without the clipboard.
    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return false }
        let element = focusedRef as! AXUIElement
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        // Only trust this path for real text roles; web views lie about being settable.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    private static func pasteViaClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        let keep: Set<NSPasteboard.PasteboardType> = [.string, .rtf, .html, .URL, .fileURL]
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types where keep.contains(t) {
                if let d = item.data(forType: t), d.count < 2_000_000 { dict[t] = d }
            }
            return dict.isEmpty ? nil : dict
        } ?? []
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }

        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9   // "v"
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)

        // Give the app time to read the clipboard before putting the old contents back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard pb.string(forType: .string) == text else { return }   // user copied something new
            pb.clearContents()
            if !saved.isEmpty {
                let items: [NSPasteboardItem] = saved.map { dict in
                    let item = NSPasteboardItem()
                    for (t, d) in dict { item.setData(d, forType: t) }
                    return item
                }
                pb.writeObjects(items)
            }
        }
        return true
    }

    /// Type text as Unicode keystrokes. Slower, but works where paste is blocked.
    static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                chunk.withUnsafeBufferPointer { p in
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: p.baseAddress)
                }
                down.flags = []
                up.flags = []
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            i += 20
            usleep(8_000)
        }
    }

    private func typeText(_ text: String) { Self.typeUnicode(text) }

    private func screenshot() async -> ToolOutput {
        let path = NSTemporaryDirectory() + "openassistant-shot.jpg"
        try? FileManager.default.removeItem(atPath: path)
        let (code, _) = await runProcess("/usr/sbin/screencapture", ["-x", "-m", "-t", "jpg", path], timeout: 15)
        guard code == 0, FileManager.default.fileExists(atPath: path) else {
            return .error("Screenshot failed. Grant Screen Recording permission to Open Assistant in System Settings → Privacy & Security.")
        }
        _ = await runProcess("/usr/bin/sips", ["-Z", "1568", path], timeout: 15)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .error("Could not read the screenshot.")
        }
        try? FileManager.default.removeItem(atPath: path)
        return .content([[
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()],
        ]])
    }

    static func truncate(_ s: String, limit: Int = 8000) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "\n…(truncated)" : t
    }
}

/// Runs a process off the main thread and returns (exit code, combined stdout+stderr).
/// Output goes to a temp file rather than a pipe, so a background child that keeps
/// running (e.g. `cmd &`) can't make us wait forever.
func runProcess(_ path: String, _ args: [String], stdin: String? = nil,
                timeout: TimeInterval) async -> (Int32, String) {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("openassistant-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            guard let outHandle = try? FileHandle(forWritingTo: outURL) else {
                cont.resume(returning: (-1, "Could not create a temp file for output."))
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = outHandle
            p.standardError = outHandle
            let inPipe = Pipe()
            if stdin != nil {
                p.standardInput = inPipe
            } else {
                p.standardInput = FileHandle.nullDevice
            }
            do { try p.run() } catch {
                try? outHandle.close()
                try? FileManager.default.removeItem(at: outURL)
                cont.resume(returning: (-1, "Failed to start \(path): \(error.localizedDescription)"))
                return
            }
            if let stdin {
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            try? outHandle.close()
            let data = (try? Data(contentsOf: outURL)) ?? Data()
            try? FileManager.default.removeItem(at: outURL)
            cont.resume(returning: (p.terminationStatus, String(decoding: data.prefix(200_000), as: UTF8.self)))
        }
    }
}
