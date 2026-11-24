import AVFoundation

/// Offline PCM rendering with AVSpeechSynthesizer.write. Nothing is ever played: the buffers are
/// copied into memory and the synthesizer never routes audio to an output.
public struct SynthesizedSpeech {
    public struct Marker: Codable, Equatable {
        public var type: String
        public var time: Double
        public var text: String
    }

    public var text: String
    public var language: String
    public var voiceIdentifier: String?
    public var sampleRate: Double
    public var samples: [Float]
    public var markers: [Marker]

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

public enum SpeechRenderError: LocalizedError {
    case noAudio, timeout
    public var errorDescription: String? {
        switch self {
        case .noAudio: return "Speech synthesizer returned no PCM data (voice may be unavailable)"
        case .timeout: return "Speech synthesis timed out"
        }
    }
}

@MainActor
public final class SpeechSynthesisRenderer {
    private var active: [AVSpeechSynthesizer] = []

    public init() {}

    nonisolated public static func language(for text: String) -> String {
        let japanese = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        return japanese ? "ja-JP" : "en-US"
    }

    public func render(text: String, language: String? = nil, timeout: TimeInterval = 20) async throws -> SynthesizedSpeech {
        let lang = language ?? Self.language(for: text)
        let utterance = AVSpeechUtterance(string: text)
        let voice = AVSpeechSynthesisVoice(language: lang)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = false
        #endif
        active.append(synthesizer)
        defer { active.removeAll { $0 === synthesizer } }

        return try await withCheckedThrowingContinuation { continuation in
            let collector = Collector()
            var finished = false
            let complete: (Result<SynthesizedSpeech, Error>) -> Void = { result in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(with: result)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                synthesizer.stopSpeaking(at: .immediate)
                complete(.failure(SpeechRenderError.timeout))
            }
            synthesizer.write(utterance, toBufferCallback: { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    let samples = collector.samples
                    guard !samples.isEmpty else { complete(.failure(SpeechRenderError.noAudio)); return }
                    complete(.success(SynthesizedSpeech(text: text, language: lang, voiceIdentifier: voice?.identifier,
                                                        sampleRate: collector.sampleRate, samples: samples, markers: collector.markers)))
                    return
                }
                collector.append(pcm)
            }, toMarkerCallback: { markers in
                collector.append(markers: markers, text: text)
            })
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples: [Float] = []
        private var rawMarkers: [(type: String, byteOffset: Int, text: String)] = []
        private var bytesPerFrame = 2.0
        private(set) var sampleRate: Double = 22050

        var samples: [Float] { lock.lock(); defer { lock.unlock() }; return _samples }
        /// `byteSampleOffset` is a byte offset into the rendered audio, converted with the buffers' frame size.
        var markers: [SynthesizedSpeech.Marker] {
            lock.lock(); defer { lock.unlock() }
            return rawMarkers.map { .init(type: $0.type, time: Double($0.byteOffset) / bytesPerFrame / max(sampleRate, 1), text: $0.text) }
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            let n = Int(buffer.frameLength)
            lock.lock(); defer { lock.unlock() }
            sampleRate = buffer.format.sampleRate
            bytesPerFrame = Double(max(buffer.format.streamDescription.pointee.mBytesPerFrame, 1))
            if let f = buffer.floatChannelData {
                _samples.append(contentsOf: UnsafeBufferPointer(start: f[0], count: n))
            } else if let i = buffer.int16ChannelData {
                _samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 32768 })
            } else if let i = buffer.int32ChannelData {
                _samples.append(contentsOf: UnsafeBufferPointer(start: i[0], count: n).map { Float($0) / 2147483648 })
            }
        }

        func append(markers: [AVSpeechSynthesisMarker], text: String) {
            lock.lock(); defer { lock.unlock() }
            let ns = text as NSString
            for m in markers {
                let type: String
                switch m.mark {
                case .phoneme: type = "phoneme"
                case .word: type = "word"
                case .sentence: type = "sentence"
                case .paragraph: type = "paragraph"
                case .bookmark: type = "bookmark"
                @unknown default: type = "other"
                }
                let range = m.textRange
                let fragment = range.location != NSNotFound && NSMaxRange(range) <= ns.length ? ns.substring(with: range) : (m.phoneme)
                rawMarkers.append((type, Int(m.byteSampleOffset), fragment))
            }
        }
    }
}
