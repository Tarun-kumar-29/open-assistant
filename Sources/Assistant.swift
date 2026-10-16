import Cocoa

/// Ties it together: hotkey → speech → Claude (with tools) → voice + panel.
@MainActor
final class Assistant {
    private(set) var config: AppConfig
    private let panel: PanelController
    let pill = PillController()
    private let speechIn: SpeechInput
    private let speechOut = SpeechOutput()
    private let client = ClaudeClient()
    private let openAI = OpenAIClient()

    var provider: Provider { Provider.named(config.provider) }
    private let tools = ToolRunner()
    private let connectors: ConnectorManager
    private let apiKeyProvider: () -> String?

    private var messages: [[String: Any]] = []
    private var lastActivity = Date.distantPast
    private var pressStart = Date()
    private var listening = false
    private var dictating = false
    /// Click-to-talk from the pill: listening stays on until the next click.
    private var toggleListening = false
    private var turnTask: Task<Void, Never>?
    private var turnID = 0
    private var turnRunning = false
    /// True once the spoken part (first line) of the current answer has ended.
    private var spokenPartDone = false
    /// messages.count before the running turn started, so an interrupted turn can be undone cleanly.
    private var turnSnapshot: Int?

    init(config: AppConfig, panel: PanelController, connectors: ConnectorManager,
         apiKeyProvider: @escaping () -> String?) {
        self.config = config
        self.panel = panel
        self.connectors = connectors
        self.apiKeyProvider = apiKeyProvider
        speechIn = SpeechInput(locale: config.speechLocale, onDevice: config.onDeviceRecognition)
        speechIn.onPartial = { [weak self] text in
            guard let self else { return }
            if self.dictating {
                self.pill.model.hint = text
            } else {
                self.panel.model.transcript = text
            }
        }
        speechIn.onLevel = { [weak self] level in self?.pill.model.level = level }
        speechOut.onFinished = { [weak self] in self?.speechFinished() }
        pill.onClick = { [weak self] in self?.pillClicked() }
        apply(config)
    }

    private func pillClicked() {
        if listening {
            toggleListening = false
            hotkeyUp()
        } else if turnRunning || speechOut.isSpeaking {
            hotkeyTapped()
        } else {
            toggleListening = true
            hotkeyDown()
            panel.model.status = "Click the pill again to send"
        }
    }

    private func setPill(_ state: PillModel.State) {
        pill.model.state = state
        if state == .idle { pill.model.level = 0; pill.model.hint = "" }
    }

    /// Show whatever is actually going on right now.
    private func refreshPill() {
        if listening { setPill(.listening) }
        else if dictating { setPill(.dictating) }
        else if turnRunning { setPill(.thinking) }
        else if speechOut.isSpeaking { setPill(.speaking) }
        else { setPill(.idle) }
    }

    func apply(_ config: AppConfig) {
        if config.provider != self.config.provider || config.model != self.config.model { messages = [] }
        self.config = config
        pill.configure(
            mode: PillMode(rawValue: config.pillMode) ?? .activeOnly,
            position: PillPosition(rawValue: config.pillPosition) ?? .bottomCenter,
            customPoint: config.pillPosition == "custom" ? CGPoint(x: config.pillCustomX, y: config.pillCustomY) : nil
        )
        speechIn.setLocale(config.speechLocale, onDevice: config.onDeviceRecognition)
        if config.transcriber == "groq", let key = Transcriber.groqKey() {
            speechIn.cloud = (key, config.groqModel,
                              config.transcribeLanguage.isEmpty ? nil : config.transcribeLanguage,
                              config.transcribePrompt)
        } else {
            speechIn.cloud = nil
        }
        speechIn.onTranscribed = { engine in ToolRunner.log("transcribed via \(engine)") }
        speechOut.configure(voiceIdentifier: config.voiceIdentifier, locale: config.speechLocale,
                            rate: config.speechRate, enabled: config.speakReplies)
    }

    func newConversation() {
        interrupt()
        messages = []
        lastActivity = .distantPast
    }

    func stopSpeaking() {
        speechOut.stop()
        panel.hide(after: 0.5)
        if !turnRunning { setPill(.idle) }
    }

    // MARK: - Push to talk

    func hotkeyDown() {
        if dictating { dictationCancelled() }
        toggleListening = false
        interrupt()
        pressStart = Date()
        do {
            try speechIn.start()
            listening = true
            setPill(.listening)
            let m = panel.model
            m.phase = .listening
            m.transcript = ""
            m.response = ""
            m.status = "Release to send"
            panel.show()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Quick tap: stop talking / cancel and hide.
    func hotkeyTapped() {
        if listening {
            hotkeyCancelled()
            return
        }
        interrupt()
        panel.hideNow()
        setPill(.idle)
    }

    func hotkeyUp() {
        guard listening else { return }
        if toggleListening { return }   // started from the pill: wait for the second click
        listening = false
        if Date().timeIntervalSince(pressStart) < 0.25 {
            // Too short to contain speech: treat like a tap.
            speechIn.cancel()
            panel.hideNow()
            setPill(.idle)
            return
        }
        setPill(.thinking)
        panel.model.status = "Transcribing…"
        speechIn.finish { [weak self] text in self?.handleTranscript(text) }
    }

    func hotkeyCancelled() {
        guard listening else { return }
        listening = false
        toggleListening = false
        speechIn.cancel()
        panel.hideNow()
        setPill(.idle)
    }

    // MARK: - Dictation (type into the focused app)

    func dictationDown() {
        if listening { hotkeyCancelled() }
        // Don't cancel a running answer (the dictation key may double as a shortcut modifier);
        // just quieten the voice so it doesn't get picked up by the mic.
        speechOut.stop()
        panel.hideNow()
        pressStart = Date()
        do {
            try speechIn.start()
            dictating = true
            setPill(.dictating)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func dictationUp() {
        guard dictating else { return }
        dictating = false
        if Date().timeIntervalSince(pressStart) < 0.25 {
            speechIn.cancel()
            setPill(.idle)
            return
        }
        setPill(.inserting)
        speechIn.finish { [weak self] text in
            Task { @MainActor in await self?.insertDictation(text) }
        }
    }

    func dictationCancelled() {
        guard dictating else { return }
        dictating = false
        speechIn.cancel()
        setPill(.idle)
    }

    private func insertDictation(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            ToolRunner.log("dictation: nothing transcribed (\(speechIn.diagnostics))")
            refreshPill()
            return
        }
        var output = text
        if config.dictationCleanup, let key = provider.key(), !key.isEmpty {
            do {
                output = try await cleanUpDictation(text, apiKey: key)
            } catch {
                ToolRunner.log("cleanup failed, using raw text: \(error.localizedDescription)")
            }
        }
        ToolRunner.insertText(output, method: config.dictationInsert)
        refreshPill()
    }

    /// Fix punctuation and casing and drop fillers, without changing the words or language.
    private func cleanUpDictation(_ text: String, apiKey: String) async throws -> String {
        let system = """
        You clean up dictated speech so it can be typed into a document or chat as-is.
        Rules: add punctuation and capitalisation; remove fillers (um, uh, "you know", repeated words);         keep every meaningful word, the speaker's language and script exactly (Hinglish stays Hinglish in Latin script,         Hindi stays Hindi); never answer, translate, summarise or add anything;         if the speaker says "new line" or "new paragraph", insert a line break. Output only the cleaned text.
        """
        let fast = config.dictationModel.isEmpty
            ? (provider.fastModel.isEmpty ? config.model : provider.fastModel)
            : config.dictationModel
        let userMsg: [[String: Any]] = [["role": "user", "content": [["type": "text", "text": text]]]]
        var out = ""
        let result = try await streamChat(model: fast, system: system, messages: userMsg, tools: [], maxTokens: 1024,
                                          apiKey: apiKey, onText: { out += $0 }, onBlockStart: { _ in })
        if out.isEmpty, let first = result.content.first, let t = first["text"] as? String { out = t }
        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text : cleaned
    }

    private func handleTranscript(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.model.status = ""
        guard !t.isEmpty else {
            ToolRunner.log("talk: nothing transcribed (\(speechIn.diagnostics))")
            panel.model.phase = .done
            panel.model.transcript = "Didn't catch that. Hold the key and speak."
            panel.hide(after: 2)
            setPill(.idle)
            return
        }
        ask(t)
    }

    // MARK: - Conversation

    func ask(_ text: String) {
        guard let key = provider.key(), !key.isEmpty else {
            showError("No \(provider.name) API key yet. Menu bar icon → Provider → Set API Key…")
            return
        }
        interrupt()
        if Date().timeIntervalSince(lastActivity) > config.conversationResetMinutes * 60
            || messages.count > 60
            || historyUsesMissingTools() {
            messages = []
        }
        stripOldImages()
        lastActivity = Date()

        let m = panel.model
        m.transcript = text
        m.response = ""
        m.status = ""
        m.toolTrail = []
        m.phase = .thinking
        panel.show()
        spokenPartDone = config.speakMode == "none" || !config.speakReplies

        turnID += 1
        let myID = turnID
        turnSnapshot = messages.count
        turnRunning = true
        setPill(.thinking)
        messages.append(["role": "user", "content": [["type": "text", "text": text]]])
        speechOut.begin()
        turnTask = Task { [weak self] in await self?.runTurn(id: myID, apiKey: key) }
    }

    /// Cancel whatever is in flight (barge-in) and undo the half-finished turn.
    private func interrupt() {
        turnTask?.cancel()
        turnTask = nil
        turnID += 1
        if let snap = turnSnapshot, snap <= messages.count {
            messages.removeSubrange(snap...)
        }
        turnSnapshot = nil
        turnRunning = false
        speechOut.stop()
        if !listening && !dictating { setPill(.idle) }
    }

    private func runTurn(id: Int, apiKey: String) async {
        do {
            for _ in 0..<12 {
                try checkCurrent(id)
                let result = try await streamChat(
                    model: config.model,
                    system: systemPrompt(),
                    messages: messages,
                    tools: currentTools(),
                    maxTokens: config.maxTokens,
                    apiKey: apiKey,
                    onText: { [weak self] t in
                        guard let self, self.turnID == id, !Task.isCancelled else { return }
                        let m = self.panel.model
                        m.phase = .responding
                        m.status = ""
                        m.response += t
                        self.feedSpeech(t)
                    },
                    onBlockStart: { [weak self] block in
                        guard let self, self.turnID == id else { return }
                        self.describe(block)
                    }
                )
                try checkCurrent(id)
                var content = result.content
                if result.stopReason != "tool_use" && result.stopReason != "pause_turn" {
                    // e.g. cut off by max_tokens mid tool call: a tool_use with no result would break every later request
                    content.removeAll { ($0["type"] as? String) == "tool_use" }
                }
                if !content.isEmpty {
                    messages.append(["role": "assistant", "content": content])
                }

                if result.stopReason == "tool_use" {
                    let uses = result.content.filter { ($0["type"] as? String) == "tool_use" }
                    if uses.isEmpty { break }
                    var results: [[String: Any]] = []
                    for use in uses {
                        let name = use["name"] as? String ?? ""
                        let useID = use["id"] as? String ?? ""
                        let input = use["input"] as? [String: Any] ?? [:]
                        let out: ToolOutput
                        if connectors.owns(name) {
                            panel.model.status = connectors.label(for: name) ?? "Working…"
                            out = await connectors.call(name, input: input)
                        } else {
                            panel.model.status = ToolRunner.friendlyName(name)
                            out = await tools.execute(name: name, input: input, confirmScripts: config.confirmScripts)
                        }
                        addToTrail(name)
                        try checkCurrent(id)
                        results.append(out.asResult(id: useID))
                    }
                    messages.append(["role": "user", "content": results])
                    if !panel.model.response.isEmpty && !panel.model.response.hasSuffix("\n") {
                        panel.model.response += "\n\n"
                    }
                    // The real spoken summary comes after the tool results; let its first line through.
                    spokenPartDone = config.speakMode == "none" || !config.speakReplies
                    continue
                }
                if result.stopReason == "pause_turn" { continue }
                break
            }

            try checkCurrent(id)
            turnSnapshot = nil
            turnRunning = false
            lastActivity = Date()
            let m = panel.model
            m.status = ""
            if m.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { m.response = "Done." }
            m.phase = .done
            if !dictating && !listening { setPill(speechOut.isSpeaking ? .speaking : .idle) }
            speechOut.end()   // fires speechFinished() once the voice is done
        } catch {
            guard turnID == id, !Task.isCancelled else { return }   // interrupted: interrupt() already cleaned up
            interrupt()
            ToolRunner.log("turn failed: \(error.localizedDescription)")
            showError(error.localizedDescription)
        }
    }

    /// Route streamed text to the voice: the whole answer, only its first line, or nothing.
    private func feedSpeech(_ t: String) {
        guard !spokenPartDone else { return }
        if config.speakMode == "all" {
            if !dictating && !listening { setPill(.speaking) }
            speechOut.feed(t)
            return
        }
        // firstLine: speak up to the first line break, then stop feeding the voice.
        if let nl = t.firstIndex(of: "\n") {
            spokenPartDone = true
            if !dictating && !listening { setPill(.speaking) }
            speechOut.feed(String(t[..<nl]) + "\n")
        } else {
            if !dictating && !listening { setPill(.speaking) }
            speechOut.feed(t)
        }
    }

    private func addToTrail(_ toolName: String) {
        let label: String
        if let l = connectors.label(for: toolName), let colon = l.firstIndex(of: ":") {
            label = String(l[..<colon])
        } else {
            switch toolName {
            case "web_search": label = "Web search"
            case "take_screenshot": label = "Screen"
            case "run_applescript", "run_shell": label = "Script"
            case "open_app", "open_url": label = "Open"
            case "remember", "forget": label = "Memory"
            default: label = toolName.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
        if !panel.model.toolTrail.contains(label) { panel.model.toolTrail.append(label) }
    }

    private func checkCurrent(_ id: Int) throws {
        if Task.isCancelled || turnID != id { throw CancellationError() }
    }

    private func speechFinished() {
        guard !turnRunning, !listening, !dictating else { return }
        setPill(.idle)
        guard panel.model.phase == .done else { return }
        panel.hide(after: config.panelHideSeconds)
    }

    private func describe(_ block: [String: Any]) {
        let type = block["type"] as? String ?? ""
        guard ["tool_use", "server_tool_use", "mcp_tool_use"].contains(type) else { return }
        let name = block["name"] as? String ?? "tool"
        if let label = connectors.label(for: name) {
            panel.model.status = label
        } else {
            panel.model.status = ToolRunner.friendlyName(name)
        }
        if type == "server_tool_use" { addToTrail(name) }
        if panel.model.response.isEmpty { panel.model.phase = .thinking }
    }

    /// Show a short informational message in the panel.
    func showNotice(_ message: String) {
        let m = panel.model
        m.phase = .done
        m.status = ""
        m.transcript = ""
        m.response = message
        panel.show()
        panel.hide(after: 8)
    }

    private func showError(_ message: String) {
        refreshPill()
        let m = panel.model
        m.phase = .error
        m.status = ""
        m.response = message
        panel.show()
        panel.hide(after: 10)
    }

    /// Old screenshots are expensive to resend; keep only a note that they happened.
    private func stripOldImages() {
        for i in messages.indices {
            guard (messages[i]["role"] as? String) == "user",
                  var content = messages[i]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for j in content.indices {
                if let inner = content[j]["content"] as? [[String: Any]],
                   inner.contains(where: { ($0["type"] as? String) == "image" }) {
                    content[j]["content"] = "[screenshot was shown here]"
                    changed = true
                }
            }
            if changed { messages[i]["content"] = content }
        }
    }

    // MARK: - Request

    private func currentTools() -> [[String: Any]] {
        var toolList = ToolRunner.definitions + connectors.toolDefinitions
        if config.webSearch && provider.isAnthropic {
            toolList.append(["type": "web_search_20250305", "name": "web_search", "max_uses": 3])
        }
        return toolList
    }

    /// If a connector was turned off, old tool calls in the history refer to tools that no longer exist.
    private func historyUsesMissingTools() -> Bool {
        let available = Set(currentTools().compactMap { $0["name"] as? String })
        for msg in messages where (msg["role"] as? String) == "assistant" {
            for block in msg["content"] as? [[String: Any]] ?? [] {
                if (block["type"] as? String) == "tool_use",
                   let name = block["name"] as? String, !available.contains(name) {
                    return true
                }
            }
        }
        return false
    }

    /// One streaming call through whichever provider is configured.
    private func streamChat(model: String, system: String, messages: [[String: Any]], tools: [[String: Any]],
                            maxTokens: Int, apiKey: String,
                            onText: (String) -> Void, onBlockStart: ([String: Any]) -> Void) async throws -> ClaudeClient.Result {
        let p = provider
        if p.isAnthropic {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": messages,
            ]
            if !tools.isEmpty { body["tools"] = tools }
            return try await client.stream(body: body, apiKey: apiKey, betas: [], onText: onText, onBlockStart: onBlockStart)
        }
        guard let base = p.resolvedBaseURL(custom: config.customBaseURL) else {
            throw SimpleError("Set the base URL for the custom provider in the config (customBaseURL).")
        }
        guard !model.isEmpty else { throw SimpleError("Pick a model from the menu bar icon → Model.") }
        return try await openAI.stream(baseURL: base, apiKey: apiKey, model: model, system: system,
                                       messages: messages, tools: tools, maxTokens: maxTokens,
                                       useMaxCompletionTokens: p.usesMaxCompletionTokens,
                                       onText: onText, onBlockStart: onBlockStart)
    }

    private func systemPrompt() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM yyyy, h:mm a"
        let now = f.string(from: Date())
        let tz = TimeZone.current.identifier
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let memory = Memory.read().trimmingCharacters(in: .whitespacesAndNewlines)
        let name = config.userName.isEmpty ? "the user" : config.userName
        let connected = connectors.connectedNames
        let apps = connected.isEmpty ? "none" : connected.joined(separator: ", ") + " (their tools are prefixed with the app name)"

        var p = """
        You are Open Assistant, a voice assistant living on \(name)'s MacBook. \(name) holds a key, speaks, and hears your reply read aloud by a text-to-speech voice.

        How to reply — this format is mandatory:
        - Line 1 is the SPOKEN summary: one short sentence, at most 15 words, plain text, no markdown. This is the only line read aloud. Make it the direct answer.
        - Then a blank line, then the DETAILS shown on screen: as short as possible, bullet points ("- ") for lists, **bold** for key values, numbered steps when order matters. Omit the details entirely when the one-liner already says everything.
        - Never repeat the summary in the details. No preamble, no sign-off, no emojis.
        - \(name) may speak English, Hindi, or Hinglish. Reply in the same mix, always written in Latin (Roman) script.
        - Speech recognition can mishear words; infer the most sensible meaning instead of asking unless it truly matters.

        Doing things:
        - You can control this Mac with your tools. Prefer open_app and open_url for launching things, run_applescript for automating apps, and run_shell only when needed.
        - Before anything destructive or that sends something to other people (deleting files, sending messages or emails, posting), say what you're about to do and ask for a yes first.
        - After using a tool, briefly say what you did. Don't read out long tool output; summarise it.
        - Use web_search for anything current (news, prices, weather, scores) when available.
        - When \(name) shares a durable fact or preference, or says "remember", save it with the remember tool.

        Context:
        - Now: \(now) (\(tz))
        - Frontmost app: \(front)
        - Connected apps: \(apps)
        """
        if !memory.isEmpty {
            p += "\n\nWhat you remember about \(name):\n\(memory)"
        }
        if !config.extraInstructions.isEmpty {
            p += "\n\nExtra instructions from \(name):\n\(config.extraInstructions)"
        }
        return p
    }
}
