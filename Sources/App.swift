import Cocoa

@main
@MainActor
struct OpenAssistantMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)   // a child process exiting early must not kill the app
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
