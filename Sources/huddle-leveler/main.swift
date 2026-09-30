import AVFoundation
import CoreAudio
import Foundation
import LevelerCore

let usage = """
usage: huddle-leveler [options]

Evens out loud and quiet speakers in Slack huddles. Taps every Slack process's
audio, mutes the original, and plays it back through a compressor. Ctrl-C (or q)
restores Slack's normal audio.

While running: press Enter to toggle bypass (A/B compare), q + Enter to quit.

what to tap:
  --app <text>        tap processes whose bundle ID or path contains <text>
                      (default: Slack)
  --pid <pid>         tap this process ID (repeatable)
  --output <text>     play to the output device whose name contains <text>
                      (default: the system default output, following changes)

leveling talkers (defaults in brackets; levels are speech RMS in dBFS):
  --target <dB>       level every talker is moved toward [-24]
  --level-ratio <n>   3 = a talker 12 dB off target ends up 4 dB off [3]
  --max-boost <dB>    most a quiet talker is raised [12]
  --max-cut <dB>      most a loud talker is turned down [15]
  --gate <dB>         below this counts as silence; the gain holds [-55]

fast downward compression (off by default):
  --threshold <dB>    level where downward compression starts [-20]
  --ratio <n>         downward compression ratio; 1 = off [1]
  --knee <dB>         soft knee width [10]
  --makeup <dB>       gain added after compression [0]

  --attack <ms>       [10]
  --release <ms>      [300]

  --ceiling <dB>      peak limiter ceiling [-0.5]
  --soften <dB>       treble cut for loud talkers, to soften a clipping mic;
                      0 = off [10]
  --no-declip         don't redraw peaks flattened by a clipping mic

other:
  --list              list processes using audio and output devices, then exit
  --curve             print input level -> output level for these settings
  --process-file <in> <out>
                      run an audio file through the compressor, for tuning
  --quiet             don't draw the level meter
  --record <prefix>   save raw and processed audio to <prefix>-raw.wav and
                      <prefix>-processed.wav: the first --record-seconds [30],
                      or what's recorded so far on SIGUSR1 or quit
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("huddle-leveler: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Arguments

var params = leveler_default_params()
var appMatch: String?
var pids: [pid_t] = []
var outputMatch: String?
var mode = "run"
var fileArgs: [String] = []
var quiet = false
var recordPrefix: String?
var recordSeconds = 30.0

var args = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value") }
    return args.removeFirst()
}
func number(_ flag: String) -> Float {
    let v = next(flag)
    guard let f = Float(v) else { fail("\(flag): '\(v)' is not a number") }
    return f
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--app": appMatch = next(a)
    case "--pid":
        guard let p = pid_t(next(a)) else { fail("--pid needs a number") }
        pids.append(p)
    case "--output": outputMatch = next(a)
    case "--target": params.target_db = number(a)
    case "--level-ratio": params.level_ratio = max(1, number(a))
    case "--max-boost": params.max_boost_db = max(0, number(a))
    case "--max-cut": params.max_cut_db = max(0, number(a))
    case "--threshold": params.threshold_db = number(a)
    case "--ratio": params.ratio = max(1, number(a))
    case "--knee": params.knee_db = max(0, number(a))
    case "--attack": params.attack_ms = max(0, number(a))
    case "--release": params.release_ms = max(0, number(a))
    case "--makeup": params.makeup_db = number(a)
    case "--gate": params.gate_db = number(a)
    case "--ceiling": params.ceiling_db = min(0, number(a))
    case "--soften": params.soften_db = max(0, number(a))
    case "--no-declip": params.declip = 0
    case "--list": mode = "list"
    case "--curve": mode = "curve"
    case "--process-file": mode = "file"; fileArgs = [next(a), next(a)]
    case "--quiet": quiet = true
    case "--record": recordPrefix = next(a)
    case "--record-seconds": recordSeconds = Double(max(1, number(a)))
    default: fail("unknown option \(a)\n\n\(usage)")
    }
}

// MARK: - One-shot modes

func runList() throws {
    print("Processes using audio (* = playing now):")
    for p in try audioProcesses().sorted(by: { $0.pid < $1.pid }) {
        let slack = isSlack(p) ? "  [slack]" : ""
        print(String(format: "  %@ %6d  %@%@", p.isPlaying ? "*" : " ", p.pid, p.displayName, slack))
    }
    let def = try? defaultOutputDevice()
    print("\nOutput devices:")
    for d in try outputDevices() {
        print("  \(d.uid == def?.uid ? "*" : " ") \(d.name)")
    }
}

func runCurve() {
    print("  input dB -> output dB  (gain)")
    for level in stride(from: -70, through: 0, by: 5) {
        let g = leveler_static_gain_db(&params, Float(level))
        print(String(format: "  %6.0f  -> %6.1f     (%+.1f)", Float(level), Float(level) + g, g))
    }
}

func runFile(_ inPath: String, _ outPath: String) throws {
    let input = try AVAudioFile(forReading: URL(fileURLWithPath: inPath))
    let format = input.processingFormat
    let channels = Int(format.channelCount)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    ]
    let output = try AVAudioFile(forWriting: URL(fileURLWithPath: outPath), settings: settings,
                                 commonFormat: .pcmFormatFloat32, interleaved: false)
    let state = leveler_create()!
    defer { leveler_destroy(state) }
    leveler_init(state, params, Float(format.sampleRate))
    let chunk: AVAudioFrameCount = 4096
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
    var interleaved = [Float](repeating: 0, count: Int(chunk) * channels)
    var inPeak: Float = 0, outPeak: Float = 0
    while input.framePosition < input.length {
        try input.read(into: buffer, frameCount: chunk)
        let n = Int(buffer.frameLength)
        if n == 0 { break }
        guard let data = buffer.floatChannelData else { fail("\(inPath): not a float PCM file") }
        for c in 0..<channels { for i in 0..<n { interleaved[i * channels + c] = data[c][i] } }
        interleaved.withUnsafeMutableBufferPointer { p in
            leveler_process_interleaved(state, p.baseAddress, p.baseAddress, UInt32(n), UInt32(channels))
        }
        for c in 0..<channels { for i in 0..<n { data[c][i] = interleaved[i * channels + c] } }
        let m = leveler_take_meters(state)
        inPeak = max(inPeak, m.in_peak)
        outPeak = max(outPeak, m.out_peak)
        try output.write(from: buffer)
    }
    print(String(format: "wrote %@ (input peak %.1f dBFS, output peak %.1f dBFS)",
                 outPath, 20 * log10(max(inPeak, 1e-9)), 20 * log10(max(outPeak, 1e-9))))
}

// MARK: - Live mode

func isSlack(_ p: AudioProcess) -> Bool { TapTarget.slack.matches(p) }

let target: TapTarget = {
    if pids.isEmpty && appMatch == nil { return .slack }
    let name = !pids.isEmpty ? "pid \(pids.map(String.init).joined(separator: ","))" : appMatch!
    return TapTarget(name: name) { p in
        if pids.contains(p.pid) { return true }
        guard let m = appMatch?.lowercased() else { return false }
        return p.bundleID.lowercased().contains(m) || p.path.lowercased().contains(m)
    }
}()

let isTTY = isatty(STDOUT_FILENO) != 0
// Line-buffer stdout so a log file or pipe sees each line as it happens.
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ line: String) {
    if isTTY && !quiet { print("\r\u{1B}[K", terminator: "") }
    print(line)
}

func meterBar(_ db: Float, width: Int = 20) -> String {
    let filled = Int(((db + 60) / 60 * Float(width)).rounded())
    let n = max(0, min(width, filled))
    return String(repeating: "█", count: n) + String(repeating: "·", count: width - n)
}

var meterTicks = 0
var logPeakIn: Float = -120
var logPeakOut: Float = -120

func drawMeter(_ m: leveler_meters, bypass: Bool) {
    guard !quiet else { return }
    let inDB = 20 * log10(max(m.in_peak, 1e-6))
    let outDB = 20 * log10(max(m.out_peak, 1e-6))
    if !isTTY {
        // Logging to a file or pipe: one line every two seconds while there's sound.
        meterTicks += 1
        logPeakIn = max(logPeakIn, inDB)
        logPeakOut = max(logPeakOut, outDB)
        if meterTicks % 20 == 0 {
            if logPeakIn > -100 {
                print(String(format: "%@ talker %.1f dB, gain %+.1f dB, peak in %.1f / out %.1f dB",
                             bypass ? "bypass" : "on", m.level_db, m.gain_db, logPeakIn, logPeakOut))
            }
            logPeakIn = -120
            logPeakOut = -120
        }
        return
    }
    let mode = bypass ? "BYPASS" : "ON    "
    let gain = bypass ? "   --  " : String(format: "%+5.1f dB", m.gain_db)
    let line = String(format: "\r\u{1B}[K[%@] in %@ %6.1f  gain %@  out %@ %6.1f",
                      mode, meterBar(inDB), inDB, gain, meterBar(outDB), outDB)
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

/// Writes interleaved stereo float samples as a 32-bit float WAV.
func writeWAV(_ samples: [Float], sampleRate: Double, to path: String) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 4)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(2)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 8); u16(8); u16(32)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: samples.count * 4)) }
    try d.write(to: URL(fileURLWithPath: path))
}

var keepAlive: [Any] = []

func runLive() {
    let controller = LevelerController(target: target, params: params)
    controller.outputNameMatch = outputMatch
    controller.onLog = log
    var recording = false
    func saveRecording() {
        let engine = controller.tapEngine
        guard let prefix = recordPrefix, engine.isRecording else { return }
        let (raw, processed) = engine.takeRecording()
        recordPrefix = nil
        do {
            try writeWAV(raw, sampleRate: engine.sampleRate, to: prefix + "-raw.wav")
            try writeWAV(processed, sampleRate: engine.sampleRate, to: prefix + "-processed.wav")
            log(String(format: "Saved %.0f s to %@-raw.wav and %@-processed.wav.",
                       Double(raw.count / 2) / engine.sampleRate, prefix, prefix))
        } catch {
            log("Could not save the recording: \(error)")
        }
    }
    controller.onMeters = { [unowned controller] m in
        drawMeter(m, bypass: controller.bypass)
        guard recordPrefix != nil else { return }
        let engine = controller.tapEngine
        if !recording {
            recording = true
            engine.startRecording(seconds: recordSeconds)
            log("Recording up to \(Int(recordSeconds)) s of raw and processed audio (kill -USR1 \(getpid()) to save early).")
        } else if engine.recordingDone {
            saveRecording()
        }
    }
    controller.onStateChange = { _ in recording = false }

    func shutdown() {
        saveRecording()
        controller.deactivate()
        if isTTY && !quiet { print("") }
        print("Stopped; \(target.name) audio is back to normal.")
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGUSR1, SIG_IGN)
    let signals = [SIGINT, SIGTERM, SIGUSR1].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler(handler: sig == SIGUSR1 ? saveRecording : shutdown)
        s.resume()
        return s
    }

    Thread.detachNewThread {
        while let line = readLine() {
            let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
            DispatchQueue.main.async {
                if cmd == "q" || cmd == "quit" { shutdown() }
                controller.bypass.toggle()
                log(controller.bypass ? "Bypass: hearing \(target.name) unprocessed." : "Leveling on.")
            }
        }
    }

    controller.activate()
    // A global keeps these alive; withExtendedLifetime around dispatchMain()
    // doesn't survive optimization, which silently dropped the signal handlers.
    keepAlive = [controller, signals]
    dispatchMain()
}

do {
    switch mode {
    case "list": try runList()
    case "curve": runCurve()
    case "file": try runFile(fileArgs[0], fileArgs[1])
    default: runLive()
    }
} catch {
    fail("\(error)")
}
