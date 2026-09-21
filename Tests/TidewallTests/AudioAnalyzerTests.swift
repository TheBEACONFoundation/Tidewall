import Foundation
import Testing
@testable import Tidewall

@Suite("Audio analysis")
struct AudioAnalyzerTests {
    let rate = 48_000.0

    /// Runs `seconds` of the signal through the analyzer the way the
    /// visualizer does: one analysis per 60 Hz frame over the newest samples.
    private func run(_ seconds: Double, _ signal: (Double) -> Float) -> (AudioAnalyzer, [AudioAnalyzer.Frame]) {
        let analyzer = AudioAnalyzer(sampleRate: rate)
        let total = Int(seconds * rate), hop = Int(rate / 60)
        let samples = (0..<total).map { signal(Double($0) / rate) }
        var frames: [AudioAnalyzer.Frame] = []
        var end = AudioAnalyzer.fftSize
        while end <= total {
            frames.append(analyzer.analyze(Array(samples[(end - AudioAnalyzer.fftSize)..<end]), deltaTime: 1.0 / 60))
            end += hop
        }
        return (analyzer, frames)
    }

    @Test func bassToneLightsTheBass() {
        let (a, _) = run(1.5) { Float(0.5 * sin(2 * .pi * 60 * $0)) }
        #expect(a.frame.bass > 0.5, "bass \(a.frame.bass)")
        #expect(a.frame.treble < 0.2, "treble \(a.frame.treble)")
        #expect(!a.frame.isSilent)
    }

    @Test func trebleToneLightsTheTreble() {
        let (a, _) = run(1.5) { Float(0.5 * sin(2 * .pi * 6000 * $0)) }
        #expect(a.frame.treble > a.frame.bass + 0.2, "treble \(a.frame.treble) bass \(a.frame.bass) spectrum \(a.frame.spectrum.map { String(format: "%.2f", $0) })")
    }

    @Test func pureTonePeaksInItsBand() {
        let (a, _) = run(1.0) { Float(0.5 * sin(2 * .pi * 1000 * $0)) }
        let peak = a.frame.spectrum.indices.max { a.frame.spectrum[$0] < a.frame.spectrum[$1] }!
        // Band i covers 30 Hz · (16 kHz / 30 Hz)^(i / 48); 1 kHz falls in band 26.
        let expected = Int(log(1000.0 / 30) / log(16_000.0 / 30) * 48)
        #expect(abs(peak - expected) <= 1, "peak band \(peak), expected \(expected)")
    }

    @Test func silenceIsStill() {
        let (a, _) = run(1.0) { _ in 0 }
        #expect(a.frame.isSilent)
        #expect(a.frame.level < 0.01)
        #expect(a.frame.beats == 0)
    }

    @Test func findsTheBeatOfAKickDrum() {
        // A 120 BPM kick: a decaying 55 Hz thump every half second over quiet hiss.
        var noise = SystemRandomNumberGenerator()
        let hiss = (0..<4096).map { _ in Float.random(in: -0.01...0.01, using: &noise) }
        let (a, _) = run(8) { t in
            let since = t.truncatingRemainder(dividingBy: 0.5)
            let kick = since < 0.25 ? 0.8 * exp(-since * 18) * sin(2 * .pi * 55 * since) : 0
            return Float(kick) + hiss[Int(t * 48_000) % hiss.count]
        }
        #expect((13...17).contains(a.frame.beats), "found \(a.frame.beats) beats in 16")
    }

    @Test func quietAndLoudMusicBothMove() {
        let (quiet, _) = run(2) { Float(0.02 * sin(2 * .pi * 80 * $0)) }
        let (loud, _) = run(2) { Float(0.8 * sin(2 * .pi * 80 * $0)) }
        #expect(quiet.frame.bass > 0.5)
        #expect(abs(quiet.frame.bass - loud.frame.bass) < 0.15, "adaptive gain: \(quiet.frame.bass) vs \(loud.frame.bass)")
    }
}
