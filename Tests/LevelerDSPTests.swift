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

    func testLoudAndQuietVoicesEndUpCloser() {
        let loud = outputRMS(inputDB: -6)
        let quiet = outputRMS(inputDB: -36)
        // 30 dB apart going in; with 4:1 above -40 they should come out within ~10 dB.
        XCTAssertLessThan(loud - quiet, 10)
        XCTAssertGreaterThan(loud - quiet, 0)
        XCTAssertGreaterThan(quiet, -36, "quiet speaker should be lifted")
        XCTAssertLessThan(loud, -6, "loud speaker should be pulled down")
    }

    func testSilenceAndNoiseAreNotBoosted() {
        var p = leveler_default_params()
        XCTAssertEqual(leveler_static_gain_db(&p, -80), 0, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -61), 0, accuracy: 0.01)
        XCTAssertEqual(leveler_static_gain_db(&p, -45), p.makeup_db, accuracy: 0.01)
    }

    func testStaticCurveAboveKnee() {
        var p = leveler_default_params()
        // -20 is 20 dB over -40 at 4:1 → -15 dB of compression, +15 makeup → 0.
        XCTAssertEqual(leveler_static_gain_db(&p, -20), -15 + p.makeup_db, accuracy: 0.01)
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
