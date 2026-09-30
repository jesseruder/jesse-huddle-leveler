import LevelerDSP
import XCTest

final class LevelerDSPTests: XCTestCase {
    let rate: Float = 48000

    /// Runs `seconds` of a stereo sine at `db` dBFS peak and returns the output
    /// RMS (dBFS) over the last half, once the detector has settled.
    func outputRMS(inputDB db: Float, params: leveler_params = leveler_default_params(),
                   bypass: Bool = false, seconds: Float = 2) -> Float {
        let s = leveler_create()!
        defer { leveler_destroy(s) }
        leveler_init(s, params, rate)
        leveler_set_bypass(s, bypass ? 1 : 0)
        let n = Int(seconds * rate)
        let amp = powf(10, db / 20)
        var buf = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = amp * sinf(2 * .pi * 220 * Float(i) / rate)
            buf[2 * i] = v
            buf[2 * i + 1] = v
        }
        buf.withUnsafeMutableBufferPointer { p in
            leveler_process_interleaved(s, p.baseAddress, p.baseAddress, UInt32(n), 2)
        }
        let tail = buf[(n)..<(2 * n)]
        let ms = tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count)
        return 10 * log10f(ms)
    }

    func testQuietVoiceIsRaisedAndLoudVoiceLeftAlone() {
        // Sine RMS is 3 dB under its peak.
        // The gain settles on a new talker over a few seconds.
        let loud = outputRMS(inputDB: -6, seconds: 10)
        let quiet = outputRMS(inputDB: -33, seconds: 10)
        XCTAssertEqual(loud, -9, accuracy: 0.1, "loud voice should pass through")
        XCTAssertEqual(quiet, -36 + 8, accuracy: 0.3, "12 dB under the target should come up 8 dB")
    }

    func testDownwardCompressionWhenEnabled() {
        var p = leveler_default_params()
        p.ratio = 4
        p.threshold_db = -40
        p.makeup_db = 15
        let loud = outputRMS(inputDB: -6, params: p)
        let quiet = outputRMS(inputDB: -36, params: p)
        XCTAssertLessThan(loud - quiet, 10)
        XCTAssertLessThan(loud, -9)
    }

    func testStaticCurve() {
        var p = leveler_default_params()
        XCTAssertEqual(leveler_static_gain_db(&p, -10), 0, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -24), 0, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -30), 4, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -48), p.max_boost_db, accuracy: 0.01)
    }

    func testSilenceAndNoiseAreNotBoosted() {
        var p = leveler_default_params()
        XCTAssertEqual(leveler_static_gain_db(&p, -80), 0, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -61), 0, accuracy: 0.01)
    }

    func testLoudOnsetAfterQuietTalkerIsNotBoosted() {
        let s = leveler_create()!
        defer { leveler_destroy(s) }
        leveler_init(s, leveler_default_params(), rate)
        let n = Int(rate) * 6
        var buf = [Float](repeating: 0, count: n * 2)
        // 5 s of a quiet talker, then a loud one.
        for i in 0..<n {
            let amp: Float = i < Int(rate) * 5 ? 0.02 : 0.7
            let v = amp * sinf(2 * .pi * 220 * Float(i) / rate)
            buf[2 * i] = v
            buf[2 * i + 1] = v
        }
        buf.withUnsafeMutableBufferPointer { leveler_process_interleaved(s, $0.baseAddress, $0.baseAddress, UInt32(n), 2) }
        // Within 20 ms of the loud onset the output shouldn't exceed the input.
        let onset = Int(rate) * 5
        let after = buf[(2 * (onset + Int(rate / 50)))..<(2 * n)].map(abs).max()!
        XCTAssertLessThanOrEqual(after, 0.7 + 1e-3)
    }

    func testCeilingHolds() {
        let s = leveler_create()!
        defer { leveler_destroy(s) }
        var p = leveler_default_params()
        p.makeup_db = 30
        leveler_init(s, p, rate)
        var buf = [Float](repeating: 0, count: 48000 * 2)
        for i in 0..<48000 { buf[2 * i] = sinf(Float(i) * 0.05) * 0.9; buf[2 * i + 1] = buf[2 * i] }
        buf.withUnsafeMutableBufferPointer { leveler_process_interleaved(s, $0.baseAddress, $0.baseAddress, 48000, 2) }
        let ceiling = powf(10, p.ceiling_db / 20)
        XCTAssertLessThanOrEqual(buf.map(abs).max()!, ceiling + 1e-4)
    }

    func testBypassIsUntouched() {
        XCTAssertEqual(outputRMS(inputDB: -6, bypass: true), -6 - 3.01, accuracy: 0.05)
    }

    func testBypassSurvivesInit() {
        let s = leveler_create()!
        defer { leveler_destroy(s) }
        leveler_set_bypass(s, 1)
        leveler_init(s, leveler_default_params(), 44100)
        XCTAssertEqual(leveler_get_bypass(s), 1)
    }
}
