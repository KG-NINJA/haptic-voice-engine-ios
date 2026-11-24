import AVFoundation

/// Mono Float PCM decoded from an audio file (anything AVAudioFile reads: WAV, AIFF, CAF, M4A/AAC, MP3).
/// The audio is only analysed; nothing is played.
public struct LoadedAudio {
    public var name: String
    public var sampleRate: Double
    public var samples: [Float]
    /// Length of the whole file; `samples` stop at `maxDuration`.
    public var sourceDuration: Double

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var truncated: Bool { sourceDuration > duration + 1e-3 }
}

public enum AudioFileError: LocalizedError {
    case empty
    public var errorDescription: String? { "The audio file has no samples" }
}

public enum AudioFileLoader {
    /// Reads at most `maxDuration` seconds from the start of the file and mixes all channels to mono.
    public static func load(url: URL, maxDuration: Double = 3.0) throws -> LoadedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(min(Double(file.length), max(0, maxDuration) * sr))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw AudioFileError.empty }
        try file.read(into: buffer, frameCount: frames)
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { throw AudioFileError.empty }
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let ch = data[c]
            for i in 0..<n { mono[i] += ch[i] }
        }
        if channels > 1 { for i in 0..<n { mono[i] /= Float(channels) } }
        return LoadedAudio(name: url.lastPathComponent, sampleRate: sr, samples: mono,
                           sourceDuration: sr > 0 ? Double(file.length) / sr : 0)
    }

    /// Writes mono Float samples as a 16-bit WAV (used for fixtures and tests).
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buffer.floatChannelData?[0] else { throw AudioFileError.empty }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { ch[i] = samples[i] }
        try file.write(from: buffer)
    }
}

public extension PulseVoice {
    /// Simple voice events for the first `options.maxDuration` seconds of an audio file.
    static func events(audioFile url: URL, options: PulseVoiceOptions = .init()) throws -> [PulseVoiceEvent] {
        let audio = try AudioFileLoader.load(url: url, maxDuration: options.maxDuration)
        return events(samples: audio.samples, sampleRate: audio.sampleRate, options: options)
    }
}
