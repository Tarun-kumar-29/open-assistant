import AVFoundation
import Foundation

/// Cloud transcription (Groq Whisper, OpenAI-compatible). Apple's recognizer is the fallback.
enum Transcriber {
    static let groqEndpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    static func groqKey() -> String? {
        if let k = Keychain.read("groq_api_key"), !k.isEmpty { return k }
        if let env = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    static func setGroqKey(_ key: String) { Keychain.write("groq_api_key", key) }

    /// Sends 16 kHz mono PCM samples as a WAV file and returns the transcript.
    static func transcribe(samples: [Int16], sampleRate: Int, model: String, language: String?, prompt: String,
                           apiKey: String) async throws -> String {
        let wav = wavData(samples: samples, sampleRate: sampleRate)
        let boundary = "----OpenAssistant\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        field("temperature", "0")
        if let language, !language.isEmpty { field("language", language) }
        if !prompt.isEmpty { field("prompt", String(prompt.prefix(600))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: groqEndpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw SimpleError("Groq transcription failed (HTTP \(status)): \(msg)")
        }
        return (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal PCM16 mono WAV container.
    static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        let dataSize = UInt32(samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(36 + dataSize); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataSize)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

/// Downsamples incoming microphone buffers to 16 kHz mono Int16 for upload.
final class PCMRecorder {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    /// Returns everything captured so far and clears the buffer.
    func drain() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let s = samples
        samples.removeAll(keepingCapacity: true)
        return s
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(samples.count) / 16_000
    }
}
