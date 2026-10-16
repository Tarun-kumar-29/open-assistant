import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = AppConfig.load()
    private var statusItem: NSStatusItem!
    private var panel: PanelController!
    private var assistant: Assistant!
    private var connectors: ConnectorManager!
    private var connectorsWindow: ConnectorsWindowController!
    private var hotkey: HotkeyMonitor?
    private var dictationHotkey: HotkeyMonitor?
    private var hotkeyRetry: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PanelController()
        connectors = ConnectorManager()
        connectorsWindow = ConnectorsWindowController()
        assistant = Assistant(config: config, panel: panel, connectors: connectors,
                              apiKeyProvider: { Keychain.apiKey() })
        setupMainMenu()
        setupStatusItem()
        assistant.pill.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        assistant.pill.onMoved = { [weak self] position, point in
            guard let self else { return }
            self.config.pillPosition = position.rawValue
            self.config.pillCustomX = point.x
            self.config.pillCustomY = point.y
            self.config.save()
        }
        connectors.startAll()

        SpeechInput.requestPermissions { [weak self] ok in
            if !ok {
                self?.alert("Microphone or Speech Recognition is off",
                            "Open System Settings → Privacy & Security and allow Open Assistant under both Microphone and Speech Recognition.")
            }
        }
        startHotkey()
        if Keychain.apiKey() == nil { setAPIKey() }
    }

    // MARK: - Hotkey

    private func startHotkey() {
        hotkey?.stop()
        hotkey = nil
        dictationHotkey?.stop()
        dictationHotkey = nil
        hotkeyRetry?.invalidate()
        hotkeyRetry = nil

        if tryStartHotkey() { return }

        // Ask macOS for the permissions the event tap needs, then keep retrying until granted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        _ = CGRequestListenEventAccess()
        rebuildMenu()
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tryStartHotkey() else { return }
                self.hotkeyRetry?.invalidate()
                self.hotkeyRetry = nil
            }
        }
    }

    private func tryStartHotkey() -> Bool {
        if !HotkeyMonitor.isDisabled(config.hotkey) {
            let hk = HotkeyMonitor(spec: config.hotkey)
            hk.onPress = { [weak self] in self?.assistant.hotkeyDown() }
            hk.onRelease = { [weak self] in self?.assistant.hotkeyUp() }
            hk.onCancel = { [weak self] in self?.assistant.hotkeyCancelled() }
            hk.onTap = { [weak self] in self?.assistant.hotkeyTapped() }
            guard hk.start() else { return false }
            hotkey = hk
        }
        if !HotkeyMonitor.isDisabled(config.dictationHotkey) && config.dictationHotkey != config.hotkey {
            let dk = HotkeyMonitor(spec: config.dictationHotkey)
            dk.onPress = { [weak self] in self?.assistant.dictationDown() }
            dk.onRelease = { [weak self] in self?.assistant.dictationUp() }
            dk.onCancel = { [weak self] in self?.assistant.dictationCancelled() }
            dk.onTap = { [weak self] in self?.assistant.dictationCancelled() }
            if dk.start() {
                dictationHotkey = dk
            } else if hotkey == nil {
                return false
            }
        }
        rebuildMenu()
        return true
    }

    // MARK: - Menu bar

    /// Menu-bar-only apps have no visible main menu, but text fields still need
    /// an Edit menu for ⌘C / ⌘V / ⌘A / ⌘Z to work.
    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Open Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Open Assistant")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard statusItem != nil else { return }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let waiting = hotkey == nil && dictationHotkey == nil
        if waiting {
            let ax = AXIsProcessTrusted()
            let listen = CGPreflightListenEventAccess()
            let missing: String
            switch (ax, listen) {
            case (false, false): missing = "Accessibility and Input Monitoring"
            case (false, true): missing = "Accessibility"
            case (true, false): missing = "Input Monitoring"
            case (true, true): missing = "a relaunch (permissions look granted)"
            }
            let item = NSMenuItem(title: "⚠️ Hotkeys off: needs \(missing)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            add(menu, "Open Accessibility Settings", #selector(openAccessibilitySettings), "")
            add(menu, "Open Input Monitoring Settings", #selector(openInputMonitoringSettings), "")
            add(menu, "Retry Hotkeys", #selector(reloadConfig), "")
        } else {
            if hotkey != nil {
                let item = NSMenuItem(title: "Hold \(HotkeyMonitor.describe(config.hotkey)) to talk · tap to stop",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            if dictationHotkey != nil {
                let item = NSMenuItem(title: "Hold \(HotkeyMonitor.describe(config.dictationHotkey)) to dictate into any app",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        add(menu, "Ask by Typing…", #selector(askByTyping), "t")
        add(menu, "New Conversation", #selector(newConversation), "n")
        add(menu, "Stop Speaking", #selector(stopSpeaking), ".")
        add(menu, "Test Dictation Insert (3 s)", #selector(testInsert), "")
        add(menu, "Open Dictation Log", #selector(openDictationLog), "")
        menu.addItem(.separator())
        menu.addItem(pillMenuItem())
        add(menu, "Connectors…", #selector(openConnectors), "k")
        add(menu, "Set Anthropic API Key…", #selector(setAPIKey), "")
        add(menu, Transcriber.groqKey() == nil ? "Set Groq API Key (better transcription)…" : "Set Groq API Key…",
            #selector(setGroqKey), "")
        menu.addItem(voiceMenuItem())
        add(menu, "Open Config File", #selector(openConfig), ",")
        add(menu, "Reload Config", #selector(reloadConfig), "r")
        add(menu, "Open Memory File", #selector(openMemory), "")
        let login = add(menu, "Launch at Login", #selector(toggleLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Open Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func pillMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Floating Pill", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let pill = assistant.pill

        let showHeader = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        showHeader.isEnabled = false
        sub.addItem(showHeader)
        for m in PillMode.allCases {
            let mi = NSMenuItem(title: m.title, action: #selector(pillModeChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = pill.mode == m ? .on : .off
            mi.indentationLevel = 1
            sub.addItem(mi)
        }
        let snooze = NSMenuItem(title: pill.isSnoozed ? "Hidden for 1 hour ✓" : "Hide for 1 Hour",
                                action: #selector(pillSnooze), keyEquivalent: "")
        snooze.target = self
        snooze.indentationLevel = 1
        snooze.isEnabled = pill.mode == .always && !pill.isSnoozed
        sub.addItem(snooze)

        sub.addItem(.separator())
        let posHeader = NSMenuItem(title: "Position (or just drag it)", action: nil, keyEquivalent: "")
        posHeader.isEnabled = false
        sub.addItem(posHeader)
        for p in PillPosition.allCases where p != .custom || pill.position == .custom {
            let pi = NSMenuItem(title: p.title, action: #selector(pillPositionChosen(_:)), keyEquivalent: "")
            pi.target = self
            pi.representedObject = p.rawValue
            pi.state = pill.position == p ? .on : .off
            pi.indentationLevel = 1
            sub.addItem(pi)
        }
        item.submenu = sub
        return item
    }

    @objc private func pillModeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = PillMode(rawValue: raw) else { return }
        assistant.pill.setMode(m)
        config.pillMode = raw
        config.save()
        rebuildMenu()
    }

    @objc private func pillPositionChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = PillPosition(rawValue: raw) else { return }
        assistant.pill.setPosition(p)
        config.pillPosition = raw
        config.save()
        rebuildMenu()
    }

    @objc private func pillSnooze() {
        assistant.pill.snooze(until: Date().addingTimeInterval(3600))
        rebuildMenu()
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func askByTyping() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Ask Open Assistant"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Type your question…"
        a.accessoryView = field
        a.addButton(withTitle: "Ask")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { assistant.ask(text) }
    }

    @objc private func newConversation() { assistant.newConversation() }

    /// Click this, then click into any text field: after 3 seconds a test sentence is inserted there.
    @objc private func testInsert() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let note = ToolRunner.insertText("Hello from Open Assistant. ", method: self.config.dictationInsert)
            self.assistant.showNotice("Test insert: \(note)")
        }
    }

    @objc private func openDictationLog() {
        let url = AppConfig.logDir.appendingPathComponent("dictation.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        openInTextEdit(url)
    }

    @objc private func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func openInputMonitoringSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func openConnectors() { connectorsWindow.show(manager: connectors) }

    @objc private func stopSpeaking() { assistant.stopSpeaking() }

    @objc private func setAPIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Anthropic API Key"
        a.informativeText = "Paste a key from console.anthropic.com. It is stored in your macOS Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-…"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Keychain.setAPIKey(key) }
    }

    @objc private func setGroqKey() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Groq API Key"
        a.informativeText = "Free key from console.groq.com → API Keys. Used for Whisper transcription (much better for Hinglish). Stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "gsk_…"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            Transcriber.setGroqKey(key)
            config.transcriber = "groq"
            config.save()
            assistant.apply(config)
            rebuildMenu()
        }
    }

    private func voiceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (raw, title) in [("firstLine", "Speak the one-line summary only"), ("all", "Speak everything"), ("none", "Don't speak, just show")] {
            let mi = NSMenuItem(title: title, action: #selector(speakModeChosen(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = raw
            mi.state = config.speakMode == raw ? .on : .off
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func speakModeChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        config.speakMode = raw
        config.speakReplies = raw != "none"
        config.save()
        assistant.apply(config)
        rebuildMenu()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: AppConfig.fileURL.path) { config.save() }
        openInTextEdit(AppConfig.fileURL)
    }

    @objc private func openMemory() {
        if !FileManager.default.fileExists(atPath: Memory.fileURL.path) {
            try? "".write(to: Memory.fileURL, atomically: true, encoding: .utf8)
        }
        openInTextEdit(Memory.fileURL)
    }

    @objc private func reloadConfig() {
        config = AppConfig.load()
        assistant.apply(config)
        startHotkey()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login",
                  "Move Open Assistant into your Applications folder and try again.\n\n\(error.localizedDescription)")
        }
        rebuildMenu()
    }

    private func openInTextEdit(_ url: URL) {
        Task { _ = await runProcess("/usr/bin/open", ["-e", url.path], timeout: 10) }
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
