import AVFoundation

/// Speaks the reply sentence by sentence while it is still streaming in.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    var onFinished: (() -> Void)?

    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var active = Set<AVSpeechUtterance>()
    private var streamOpen = false
    private var enabled = true
    private var rate: Float = 0.52
    private var voice: AVSpeechSynthesisVoice?

    override init() {
        super.init()
        synth.delegate = self
    }

    func configure(voiceIdentifier: String, locale: String, rate: Double, enabled: Bool) {
        self.enabled = enabled
        self.rate = Float(rate)
        if !voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            voice = v
            return
        }
        let lang = locale.replacingOccurrences(of: "_", with: "-")
        let matches = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        voice = matches.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: lang)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    var isSpeaking: Bool { !active.isEmpty }

    func begin() {
        stop()
        streamOpen = true
    }

    func feed(_ text: String) {
        guard enabled, streamOpen else { return }
        buffer += text
        while let end = sentenceEnd(in: buffer) {
            let sentence = String(buffer[..<end])
            buffer = String(buffer[end...])
            speak(sentence)
        }
    }

    /// Call when the reply is complete.
    func end() {
        if streamOpen {
            streamOpen = false
            if enabled { speak(buffer) }
            buffer = ""
        }
        if active.isEmpty { onFinished?() }
    }

    func stop() {
        buffer = ""
        streamOpen = false
        active.removeAll()
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(_ raw: String) {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return }
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        if let voice { u.voice = voice }
        active.insert(u)
        synth.speak(u)
    }

    private func finished(_ u: AVSpeechUtterance) {
        guard active.remove(u) != nil else { return }
        if active.isEmpty && !streamOpen { onFinished?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    /// Index just past the first complete sentence, if any.
    private func sentenceEnd(in s: String) -> String.Index? {
        var prev: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\n" { return s.index(after: i) }
            if let p = prev, ".!?।".contains(p), c == " " { return s.index(after: i) }
            prev = c
            i = s.index(after: i)
        }
        return nil
    }

    /// Strip markdown and links so the voice doesn't read symbols aloud.
    static func clean(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for sym in ["**", "__", "`", "#", "*", "•"] { t = t.replacingOccurrences(of: sym, with: "") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
