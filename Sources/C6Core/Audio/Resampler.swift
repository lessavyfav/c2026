import Foundation

/// Band-limited sample-rate conversion (windowed sinc, Kaiser window), used to send samples at
/// 22.05 kHz to save device memory. Downsampling low-passes at 47% of the new rate first, so
/// content above the new Nyquist frequency is removed rather than aliased.
public enum Resampler {
    /// The rate C2026 offers as the space-saving option.
    public static let halfRate = 22_050

    /// Resamples `x` (any scale) from `inRate` to `outRate`. Returns `x` unchanged if the rates match.
    public static func resample(_ x: [Double], from inRate: Int, to outRate: Int, halfWidth zeroCrossings: Int = 24) -> [Double] {
        guard inRate > 0, outRate > 0, inRate != outRate, !x.isEmpty else { return x }
        let ratio = Double(outRate) / Double(inRate)               // < 1 when downsampling
        let outCount = Int((Double(x.count) * ratio).rounded(.up))
        // Cutoff in cycles per input sample; below both Nyquists.
        let fc = 0.5 * min(1, ratio) * 0.94
        let halfWidth = Double(zeroCrossings) / (2 * fc)           // in input samples
        // Kaiser window (β = 8) as a lookup table over u ∈ [0, 1] — computing the Bessel function
        // per tap is the slow part otherwise.
        let beta = 8.0, i0beta = besselI0(beta), tableSize = 4096
        let window = (0...tableSize).map { i -> Double in
            let u = Double(i) / Double(tableSize)
            return besselI0(beta * max(0, 1 - u * u).squareRoot()) / i0beta
        }
        var y = [Double](repeating: 0, count: outCount)
        x.withUnsafeBufferPointer { xs in
            for n in 0..<outCount {
                let t = Double(n) / ratio                           // position in input samples
                let k0 = max(0, Int((t - halfWidth).rounded(.up)))
                let k1 = min(xs.count - 1, Int((t + halfWidth).rounded(.down)))
                if k0 > k1 { continue }
                var acc = 0.0, wsum = 0.0
                for k in k0...k1 {
                    let d = t - Double(k)
                    let wv = window[min(tableSize, Int(abs(d) / halfWidth * Double(tableSize) + 0.5))]
                    let arg = 2 * fc * d
                    let sinc = arg == 0 ? 1.0 : sin(.pi * arg) / (.pi * arg)
                    let w = 2 * fc * sinc * wv
                    acc += xs[k] * w; wsum += w
                }
                // Normalise by the kernel sum: unity gain at DC even near the edges.
                y[n] = wsum != 0 ? acc / wsum : 0
            }
        }
        return y
    }

    /// Resamples bits-wide integer samples, clipping to the bit range.
    public static func resample(_ s: [Int32], bits: Int, from inRate: Int, to outRate: Int) -> [Int32] {
        guard inRate != outRate else { return s }
        let maxV = Double((1 << (bits - 1)) - 1), minV = -Double(1 << (bits - 1))
        return resample(s.map(Double.init), from: inRate, to: outRate).map { Int32(min(maxV, max(minV, $0.rounded()))) }
    }

    /// Modified Bessel function of the first kind, order 0 (for the Kaiser window).
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let q = x * x / 4
        for k in 1..<50 {
            term *= q / Double(k * k)
            sum += term
            if term < sum * 1e-12 { break }
        }
        return sum
    }
}

/// What a Machinedrum will play back: mono, at the rate sent, at 12-bit resolution.
public enum MachinedrumPreview {
    /// How a device steps through a sample whose content rate is below its output rate (a 22 kHz
    /// sample, or a 2× sample at pitch −12). The Machinedrum's method isn't documented; compare
    /// by ear and pick the closer one.
    public enum Interpolation: String, Codable, CaseIterable, Sendable {
        case linear = "Smooth (linear)"
        case hold = "Gritty (sample & hold)"
    }

    /// The Machinedrum's output rate.
    public static let deviceRate = 44_100

    /// Steps through `s` at 1/`factor` speed (factor 2 = an octave down): `factor`× the frames,
    /// interpolated between neighbours.
    public static func stretch(_ s: [Int32], by factor: Int, interpolation: Interpolation) -> [Int32] {
        guard factor > 1, !s.isEmpty else { return s }
        var out = [Int32](); out.reserveCapacity(s.count * factor)
        for i in 0..<s.count {
            let a = Int64(s[i]), b = Int64(i + 1 < s.count ? s[i + 1] : s[i])
            for j in 0..<factor {
                switch interpolation {
                case .hold: out.append(s[i])
                case .linear: out.append(Int32(a + (b - a) * Int64(j) / Int64(factor)))
                }
            }
        }
        return out
    }

    /// Keeps the top 12 bits of `bits`-wide samples (the MD plays back at 12 bits); samples of 12
    /// bits or fewer are unchanged. Values stay `bits` wide.
    public static func quantize12(_ s: [Int32], bits: Int) -> [Int32] {
        guard bits > 12 else { return s }
        let shift = Int32(bits - 12)
        return s.map { ($0 >> shift) << shift }
    }

    /// A 16-bit mono WAV of `sample` as the device will play it.
    /// - `octaveDown`: a 2× sample played with the device's pitch at −12 (its content rate is half
    ///   the header rate).
    /// - `emulateDevice`: step through the content at the device's 44.1 kHz output with
    ///   `interpolation` when the content rate divides it (22.05 kHz, 11.025 kHz…), and quantise to
    ///   12 bits; otherwise the content plays at its own rate.
    public static func wav(for sample: SDSSample, emulateDevice: Bool = true, octaveDown down: Bool = false,
                           interpolation: Interpolation = .hold) -> [UInt8] {
        var v = sample.samples
        var rate = down ? max(1, sample.sampleRate / 2) : sample.sampleRate     // content rate
        if emulateDevice, rate < deviceRate, deviceRate % rate == 0 {
            v = stretch(v, by: deviceRate / rate, interpolation: interpolation)
            rate = deviceRate
        }
        if emulateDevice { v = quantize12(v, bits: sample.bits) }
        // Re-scale to 16-bit for the player.
        if sample.bits != 16 {
            v = v.map { sample.bits > 16 ? $0 >> Int32(sample.bits - 16) : $0 << Int32(16 - sample.bits) }
        }
        return AudioWriter.wav(samples: v, bits: 16, sampleRate: rate)
    }
}

public extension SDSSample {
    /// The same sample at another rate (loop points scaled), e.g. 22.05 kHz to save memory.
    func resampled(to rate: Int) -> SDSSample {
        let from = sampleRate
        guard rate < from else { return self }
        var s = self
        s.samples = Resampler.resample(samples, bits: bits, from: from, to: rate)
        s.sampleRateHz = rate
        s.samplePeriodNs = SDSSample.period(forRate: rate)
        let r = Double(rate) / Double(from)
        s.loopStart = Int((Double(loopStart) * r).rounded())
        s.loopEnd = min(max(0, s.samples.count - 1), Int((Double(loopEnd) * r).rounded()))
        return s
    }
}
