import AVFoundation
import Speech

/// Push-to-talk speech recognition using Apple's Speech framework.
@MainActor
final class SpeechInput {
    var onPartial: ((String) -> Void)?
    /// Microphone level 0…1 while listening.
    var onLevel: ((Float) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var onDevice: Bool
    private var engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var completion: ((String) -> Void)?
    private var session = 0
    private let recorder = PCMRecorder()
    /// Cloud transcription settings; nil model = Apple only.
    var cloud: (key: String, model: String, language: String?, prompt: String)?
    /// Called after finish() with which engine produced the final text.
    var onTranscribed: ((String) -> Void)?
    private var peakLevel: Float = 0
    private var lastError: String?

    /// Why the last session may have produced nothing; for the log.
    var diagnostics: String {
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "authorized"
        case .denied: speech = "DENIED"
        case .restricted: speech = "restricted"
        case .notDetermined: speech = "not asked"
        @unknown default: speech = "?"
        }
        let mic: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = "authorized"
        case .denied: mic = "DENIED"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "not asked"
        @unknown default: mic = "?"
        }
        let avail = recognizer?.isAvailable == true ? "available" : "UNAVAILABLE"
        return "speech=\(speech) mic=\(mic) recognizer=\(avail) locale=\(recognizer?.locale.identifier ?? "?") peakLevel=\(String(format: "%.2f", peakLevel)) error=\(lastError ?? "none")"
    }

    init(locale: String, onDevice: Bool) {
        self.onDevice = onDevice
        setLocale(locale, onDevice: onDevice)
    }

    func setLocale(_ locale: String, onDevice: Bool) {
        self.onDevice = onDevice
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    static func requestPermissions(_ done: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable mic in
                Task { @MainActor in done(status == .authorized && mic) }
            }
        }
    }

    func start() throws {
        cancel()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SimpleError("Speech recognition is not allowed. Enable it in System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw SimpleError("Speech recognition is unavailable right now (check your internet or the speechLocale setting).")
        }

        session += 1
        let mySession = session
        transcript = ""
        peakLevel = 0
        lastError = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if onDevice && recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SimpleError("No microphone available. Check System Settings → Privacy & Security → Microphone.")
        }
        _ = recorder.drain()
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            req.append(buffer)
            recorder.append(buffer)
            let level = SpeechInput.rms(buffer)
            Task { @MainActor in
                guard let self, self.session == mySession else { return }
                if level > self.peakLevel { self.peakLevel = level }
                self.onLevel?(level)
            }
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            let errText = error.map { ($0 as NSError).domain + " " + String(($0 as NSError).code) + ": " + $0.localizedDescription }
            Task { @MainActor in
                guard let self, self.session == mySession else { return }
                if let errText { self.lastError = errText }
                if let text, !text.isEmpty {
                    self.transcript = text
                    self.onPartial?(text)
                }
                if isFinal || failed { self.complete() }
            }
        }
    }

    /// Stop listening and deliver the final transcript.
    /// With a cloud transcriber configured, the recorded audio is uploaded and Apple's text is only a fallback.
    func finish(_ done: @escaping (String) -> Void) {
        stopAudio()
        request?.endAudio()
        let mySession = session
        let audio = recorder.drain()
        let seconds = Double(audio.count) / 16_000

        if let cloud, seconds >= 0.4 {
            // Apple keeps settling in the background as the fallback while the upload runs.
            completion = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let text = try await Transcriber.transcribe(samples: audio, sampleRate: 16_000, model: cloud.model,
                                                                language: cloud.language, prompt: cloud.prompt, apiKey: cloud.key)
                    guard self.session == mySession else { return }
                    self.task?.cancel()
                    self.task = nil
                    self.request = nil
                    self.onTranscribed?("groq/\(cloud.model) \(String(format: "%.1f", seconds))s")
                    done(text.isEmpty ? self.transcript : text)
                } catch {
                    guard self.session == mySession else { return }
                    self.lastError = error.localizedDescription
                    self.onTranscribed?("groq failed → apple: \(error.localizedDescription)")
                    self.completion = done
                    self.complete()
                }
            }
            return
        }

        completion = done
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.session == mySession else { return }
            self.onTranscribed?("apple")
            self.complete()
        }
    }

    func cancel() {
        completion = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        session += 1
    }

    private func complete() {
        guard let done = completion else { return }
        completion = nil
        task?.finish()
        task = nil
        request = nil
        done(transcript)
    }

    /// Rough loudness of a buffer, mapped to 0…1.
    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        // -50 dB → 0, -10 dB → 1
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 50) / 40))
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }
}
