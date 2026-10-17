import EMCore
import Foundation
import Testing
@testable import EMAudio

@Suite("Live audio tap")
struct LiveAudioTapTests {
    @Test func resamples48kTo16k() {
        let tap = LiveAudioTap(includesMic: true, bufferSeconds: 5)
        let tone = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        tap.push(.system, tone, rate: 48_000)
        tap.push(.system, tone, rate: 48_000)
        let out = tap.drain16k(.system) + tap.drain16k(.system)
        #expect(out.count > 30_000 && out.count <= 32_100)        // ≈ 2 s at 16 kHz (converter keeps a few samples)
        #expect(tap.drain16k(.mic).isEmpty)
    }

    @Test func passesThrough16k() {
        let tap = LiveAudioTap(includesMic: false, bufferSeconds: 5)
        tap.push(.system, [Float](repeating: 0.25, count: 1_600), rate: 16_000)
        #expect(tap.drain16k(.system) == [Float](repeating: 0.25, count: 1_600))
        #expect(tap.tracks == [.system])
    }

    @Test func dropsWhenNobodyReads() {
        let tap = LiveAudioTap(includesMic: false, bufferSeconds: 1, maxInputRate: 16_000)
        tap.push(.system, [Float](repeating: 0.1, count: 40_000), rate: 16_000)
        #expect(tap.dropped > 0)                                   // never blocks the recording
    }
}
