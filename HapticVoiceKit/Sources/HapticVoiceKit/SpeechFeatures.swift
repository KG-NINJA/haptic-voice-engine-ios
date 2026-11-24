import Accelerate
import Foundation

public struct SpeechFeatures: Codable, Equatable {
    public var hop: Double
    public var times: [Double]
    public var rms: [Float]
    public var envelope: [Float]
    /// 0 where unvoiced.
    public var f0: [Float]
    public var voiced: [Bool]
    public var centroid: [Float]
    /// LPC-envelope peak estimates for voiced frames, 0 where not estimated. Rough estimates only.
    public var f1: [Float]
    public var f2: [Float]
    public var duration: Double

    public struct Summary: Codable, Equatable {
        public var duration: Double
        public var voicedFraction: Double
        public var meanF0: Double?
        public var meanCentroid: Double
        public var medianF1: Double?
        public var medianF2: Double?
        public var peakRMS: Double
    }

    public var summary: Summary {
        let voicedIdx = voiced.indices.filter { voiced[$0] }
        func mean(_ xs: [Float]) -> Double? { xs.isEmpty ? nil : Double(xs.reduce(0, +)) / Double(xs.count) }
        func median(_ xs: [Float]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted(); return Double(s[s.count / 2])
        }
        let active = envelope.indices.filter { envelope[$0] > 0.1 }
        return Summary(duration: duration,
                       voicedFraction: times.isEmpty ? 0 : Double(voicedIdx.count) / Double(times.count),
                       meanF0: mean(voicedIdx.map { f0[$0] }),
                       meanCentroid: mean(active.map { centroid[$0] }) ?? 0,
                       medianF1: median(voicedIdx.map { f1[$0] }.filter { $0 > 0 }),
                       medianF2: median(voicedIdx.map { f2[$0] }.filter { $0 > 0 }),
                       peakRMS: Double(rms.max() ?? 0))
    }
}

/// Frame-based analysis with vDSP: RMS, normalized envelope, autocorrelation F0, spectral centroid
/// and LPC formant estimates.
public enum SpeechFeatureExtractor {
    public static let hopSeconds = 0.01
    public static let windowSeconds = 0.025
    public static let fftLog2n: vDSP_Length = 11

    public static func extract(samples input: [Float], sampleRate: Double) -> SpeechFeatures {
        var samples = trimSilence(input)
        let hop = max(1, Int(sampleRate * hopSeconds))
        let win = max(16, Int(sampleRate * windowSeconds))
        if !samples.isEmpty && samples.count < win { samples += [Float](repeating: 0, count: win - samples.count) }
        let frameCount = samples.count >= win ? (samples.count - win) / hop + 1 : 0
        let fftSize = 1 << Int(fftLog2n)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: win, isHalfWindow: false)
        let fft = vDSP.FFT(log2n: fftLog2n, radix: .radix2, ofType: DSPSplitComplex.self)

        var rms = [Float](), f0 = [Float](), voiced = [Bool](), centroid = [Float](), f1 = [Float](), f2 = [Float]()
        rms.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let frame = Array(samples[(i * hop)..<(i * hop + win)])
            rms.append(vDSP.rootMeanSquare(frame))
        }
        let peak = max(rms.max() ?? 0, 1e-9)
        for i in 0..<frameCount {
            let frame = Array(samples[(i * hop)..<(i * hop + win)])
            let loud = rms[i] > 0.05 * peak
            let pitch = loud ? estimateF0(frame, sampleRate: sampleRate) : nil
            f0.append(pitch ?? 0)
            voiced.append(pitch != nil)
            let windowed = vDSP.multiply(frame, window)
            centroid.append(loud ? spectralCentroid(windowed, sampleRate: sampleRate, fft: fft, size: fftSize) : 0)
            if pitch != nil, let formants = estimateFormants(windowed, sampleRate: sampleRate) {
                f1.append(formants.0); f2.append(formants.1)
            } else {
                f1.append(0); f2.append(0)
            }
        }
        let envelope = smooth(rms.map { $0 / peak }, radius: 2)
        return SpeechFeatures(hop: Double(hop) / sampleRate,
                              times: (0..<frameCount).map { Double($0 * hop) / sampleRate },
                              rms: rms, envelope: envelope, f0: f0, voiced: voiced, centroid: centroid,
                              f1: f1, f2: f2, duration: Double(samples.count) / sampleRate)
    }

    public static func trimSilence(_ samples: [Float], threshold: Float = 0.01) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return samples }
        return Array(samples[first...last])
    }

    public static func smooth(_ xs: [Float], radius: Int) -> [Float] {
        guard radius > 0, !xs.isEmpty else { return xs }
        return xs.indices.map { i in
            let lo = max(0, i - radius), hi = min(xs.count - 1, i + radius)
            return xs[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
    }

    /// Normalized autocorrelation pitch estimate within 70-400 Hz; nil when the periodicity is weak.
    /// Picks the shortest lag whose correlation is within 10% of the best, avoiding octave errors.
    public static func estimateF0(_ frame: [Float], sampleRate: Double, minHz: Double = 70, maxHz: Double = 400) -> Float? {
        let minLag = max(1, Int(sampleRate / maxHz)), maxLag = min(Int(sampleRate / minHz), frame.count / 2)
        guard maxLag > minLag else { return nil }
        let x = vDSP.add(-vDSP.mean(frame), frame)
        guard vDSP.sumOfSquares(x) > 0 else { return nil }
        let r: [Float] = x.withUnsafeBufferPointer { p in
            (minLag...maxLag).map { lag in
                let n = x.count - lag
                let a = UnsafeBufferPointer(rebasing: p[0..<n]), b = UnsafeBufferPointer(rebasing: p[lag..<(lag + n)])
                let denom = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
                return denom > 0 ? vDSP.dot(a, b) / denom : 0
            }
        }
        guard let best = r.max(), best > 0.5 else { return nil }
        for i in r.indices where r[i] >= 0.9 * best {
            let left = i > 0 ? r[i - 1] : -1, right = i + 1 < r.count ? r[i + 1] : -1
            if r[i] >= left && r[i] >= right {
                var offset: Float = 0
                if i > 0 && i + 1 < r.count {
                    let d = left - 2 * r[i] + right
                    if d != 0 { offset = 0.5 * (left - right) / d }
                }
                return Float(sampleRate) / (Float(minLag + i) + offset)
            }
        }
        return nil
    }

    public static func spectralCentroid(_ frame: [Float], sampleRate: Double, fft: vDSP.FFT<DSPSplitComplex>?, size: Int) -> Float {
        guard let fft else { return 0 }
        let mags = powerSpectrum(frame, fft: fft, size: size)
        let total = vDSP.sum(mags)
        guard total > 0 else { return 0 }
        let binHz = Float(sampleRate) / Float(size)
        let freqs = (0..<mags.count).map { Float($0) * binHz }
        return vDSP.dot(freqs, mags) / total
    }

    public static func powerSpectrum(_ frame: [Float], fft: vDSP.FFT<DSPSplitComplex>, size: Int) -> [Float] {
        var padded = [Float](repeating: 0, count: size)
        for (i, v) in frame.prefix(size).enumerated() { padded[i] = v }
        let half = size / 2
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var outReal = [Float](repeating: 0, count: half), outImag = [Float](repeating: 0, count: half)
        return real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                outReal.withUnsafeMutableBufferPointer { orp in
                    outImag.withUnsafeMutableBufferPointer { oip in
                        var input = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        padded.withUnsafeBytes { raw in
                            vDSP.convert(interleavedComplexVector: Array(raw.bindMemory(to: DSPComplex.self)), toSplitComplexVector: &input)
                        }
                        var output = DSPSplitComplex(realp: orp.baseAddress!, imagp: oip.baseAddress!)
                        fft.forward(input: input, output: &output)
                        var mags = [Float](repeating: 0, count: half)
                        vDSP.squareMagnitudes(output, result: &mags)
                        return mags
                    }
                }
            }
        }
    }

    /// LPC (autocorrelation + Levinson-Durbin) envelope peaks between 200 and 3500 Hz.
    public static func estimateFormants(_ frame: [Float], sampleRate: Double) -> (Float, Float)? {
        var x = frame
        for i in stride(from: x.count - 1, to: 0, by: -1) { x[i] -= 0.97 * x[i - 1] }
        let order = min(2 + Int(sampleRate / 1000), 30)
        guard x.count > order * 2 else { return nil }
        var r = [Double](repeating: 0, count: order + 1)
        for k in 0...order {
            var s = 0.0
            for i in k..<x.count { s += Double(x[i]) * Double(x[i - k]) }
            r[k] = s
        }
        guard r[0] > 0, let a = levinson(r, order: order) else { return nil }
        let points = 512
        let maxHz = 3500.0
        var env = [Double](repeating: 0, count: points)
        for j in 0..<points {
            let w = 2 * Double.pi * (maxHz * Double(j) / Double(points)) / sampleRate
            var re = 1.0, im = 0.0
            for k in 1...order { re += a[k] * cos(w * Double(k)); im -= a[k] * sin(w * Double(k)) }
            env[j] = 1 / max(re * re + im * im, 1e-12)
        }
        var peaks: [Double] = []
        for j in 1..<(points - 1) where env[j] > env[j - 1] && env[j] > env[j + 1] {
            let hz = maxHz * Double(j) / Double(points)
            if hz > 200 { peaks.append(hz) }
        }
        guard peaks.count >= 2 else { return nil }
        return (Float(peaks[0]), Float(peaks[1]))
    }

    public static func levinson(_ r: [Double], order: Int) -> [Double]? {
        var a = [Double](repeating: 0, count: order + 1)
        a[0] = 1
        var e = r[0]
        for i in 1...order {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            let k = -acc / e
            var next = a
            for j in 1..<i { next[j] = a[j] + k * a[i - j] }
            next[i] = k
            a = next
            e *= (1 - k * k)
            if e <= 0 { return nil }
        }
        return a
    }
}
