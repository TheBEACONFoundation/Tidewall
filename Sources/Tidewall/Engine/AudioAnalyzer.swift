import Accelerate
import Foundation

/// Turns the most recent audio samples into what a visualizer draws: a
/// log-spaced spectrum, bass / mid / treble energy, overall level and beats.
///
/// Levels are normalized against a slowly adapting peak, so quiet podcasts and
/// loud music both move the picture, and every value is smoothed with a fast
/// attack and a slower release so motion reads as musical rather than jittery.
final class AudioAnalyzer {
    static let fftSize = 2048
    static let bandCount = 48

    struct Frame: Equatable {
        /// Per band, 0…1, low to high frequencies.
        var spectrum = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var level: Float = 0
        /// 1 at a beat, decaying towards 0.
        var beat: Float = 0
        /// Seconds since the last beat.
        var beatAge: Float = 10
        var beats = 0
        var isSilent = true
    }

    private(set) var frame = Frame()
    let sampleRate: Double

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imag = [Float](repeating: 0, count: fftSize / 2)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var power = [Float](repeating: 0, count: fftSize / 2)
    /// Bin range per band, log-spaced from 30 Hz to 16 kHz.
    private let bandBins: [(Int, Int)]
    private var peakDB: Float = -30
    private var bassHistory: [Float] = []
    private var sinceBeat: Double = 10

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(Self.fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
        let binHz = sampleRate / Double(Self.fftSize)
        let low = 30.0, high = min(16_000, sampleRate / 2 * 0.95)
        bandBins = (0..<Self.bandCount).map { i in
            let f0 = low * pow(high / low, Double(i) / Double(Self.bandCount))
            let f1 = low * pow(high / low, Double(i + 1) / Double(Self.bandCount))
            let b0 = max(1, Int((f0 / binHz).rounded(.down)))
            return (b0, max(b0, Int((f1 / binHz).rounded(.up)) - 1))
        }
    }

    /// Analyzes the newest `fftSize` samples (mono, -1…1). `deltaTime` is the
    /// time since the previous call and sets how far smoothing moves.
    @discardableResult
    func analyze(_ samples: [Float], deltaTime: Double) -> Frame {
        precondition(samples.count >= Self.fftSize)
        let dt = Float(max(1.0 / 240, min(0.25, deltaTime)))
        sinceBeat += Double(dt)

        // Window, then a real FFT of the packed signal.
        samples.withUnsafeBufferPointer { src in
            vDSP.multiply(UnsafeBufferPointer(rebasing: src[(src.count - Self.fftSize)...]), window, result: &windowed)
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                }
                fft.forward(input: split, output: &split)
                split.imagp[0] = 0 // packed Nyquist term
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        // Band power in dB, normalized against an adaptive peak.
        let scale = 1 / Float(Self.fftSize * Self.fftSize)
        var bandDB = [Float](repeating: -120, count: Self.bandCount)
        var loudest: Float = -120
        for (i, (b0, b1)) in bandBins.enumerated() {
            var sum: Float = 0
            for b in b0...min(b1, power.count - 1) { sum += power[b] }
            let db = 10 * log10(max(sum * scale / Float(b1 - b0 + 1), 1e-12))
            bandDB[i] = db
            loudest = max(loudest, db)
        }
        let silent = loudest < -85
        // The peak follows loud passages at once and relaxes over ~6 s.
        peakDB = loudest > peakDB ? loudest : max(-60, peakDB - 3 * dt)
        let floorDB = peakDB - 48

        var next = frame
        next.isSilent = silent
        for i in 0..<Self.bandCount {
            let target = silent ? 0 : max(0, min(1, (bandDB[i] - floorDB) / (peakDB - floorDB)))
            next.spectrum[i] = smooth(frame.spectrum[i], target, attack: 0.02, release: 0.22, dt: dt)
        }
        let n = Self.bandCount
        // A region is as loud as its loudest band, softened by its average, so
        // a lone lead line registers as much as a wall of sound.
        func energy(_ range: Range<Int>) -> Float {
            let values = range.map { next.spectrum[$0] }
            return 0.4 * values.reduce(0, +) / Float(values.count) + 0.6 * (values.max() ?? 0)
        }
        next.bass = energy(0..<n / 4)          // ~30–150 Hz
        next.mid = energy(n / 4..<n * 3 / 4)   // ~150 Hz–3 kHz
        next.treble = energy(n * 3 / 4..<n)    // ~3–16 kHz
        next.level = energy(0..<n)

        // Beats: bass power jumping well above its recent average.
        let bassPower = (0..<n / 4).reduce(Float(0)) { $0 + pow(10, bandDB[$1] / 10) }
        let history = bassHistory.isEmpty ? bassPower : bassHistory.reduce(0, +) / Float(bassHistory.count)
        bassHistory.append(bassPower)
        if bassHistory.count > Int(1.2 / Double(dt)) { bassHistory.removeFirst(bassHistory.count - Int(1.2 / Double(dt))) }
        if !silent, bassPower > history * 1.45, sinceBeat > 0.28, loudestBass(bandDB) > floorDB + 18 {
            sinceBeat = 0
            next.beat = 1
            next.beats += 1
        } else {
            next.beat = frame.beat * exp(-dt / 0.18)
        }
        next.beatAge = Float(sinceBeat)
        frame = next
        return next
    }

    private func loudestBass(_ bandDB: [Float]) -> Float {
        bandDB[0..<Self.bandCount / 4].max() ?? -120
    }

    private func smooth(_ current: Float, _ target: Float, attack: Float, release: Float, dt: Float) -> Float {
        let tau = target > current ? attack : release
        return current + (target - current) * (1 - exp(-dt / tau))
    }
}
