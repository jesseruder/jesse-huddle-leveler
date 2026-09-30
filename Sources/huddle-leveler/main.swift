import AVFoundation
import CoreAudio
import Foundation
import LevelerDSP

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

raising quiet voices (defaults in brackets; levels are short-term RMS dBFS):
  --boost-below <dB>  voices quieter than this are raised toward it [-24]
  --boost-ratio <n>   3 = a voice 12 dB under comes out 4 dB under [3]
  --max-boost <dB>    most any voice is raised [12]
  --gate <dB>         below this, boost fades out so noise isn't lifted [-55]

taming loud voices (off by default):
  --threshold <dB>    level where downward compression starts [-20]
  --ratio <n>         downward compression ratio; 1 = off [1]
  --knee <dB>         soft knee width [10]
  --makeup <dB>       gain added after compression [0]

  --attack <ms>       [10]
  --release <ms>      [300]

  --ceiling <dB>      peak limiter ceiling [-0.5]

other:
  --list              list processes using audio and output devices, then exit
  --curve             print input level -> output level for these settings
  --process-file <in> <out>
                      run an audio file through the compressor, for tuning
  --quiet             don't draw the level meter
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
    case "--boost-below": params.boost_below_db = number(a)
    case "--boost-ratio": params.boost_ratio = max(1, number(a))
    case "--max-boost": params.max_boost_db = max(0, number(a))
    case "--threshold": params.threshold_db = number(a)
    case "--ratio": params.ratio = max(1, number(a))
    case "--knee": params.knee_db = max(0, number(a))
    case "--attack": params.attack_ms = max(0, number(a))
    case "--release": params.release_ms = max(0, number(a))
    case "--makeup": params.makeup_db = number(a)
    case "--gate": params.gate_db = number(a)
    case "--ceiling": params.ceiling_db = min(0, number(a))
    case "--list": mode = "list"
    case "--curve": mode = "curve"
    case "--process-file": mode = "file"; fileArgs = [next(a), next(a)]
    case "--quiet": quiet = true
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

let ownPID = getpid()

func isSlack(_ p: AudioProcess) -> Bool {
    p.bundleID.hasPrefix("com.tinyspeck.slackmacgap") || p.path.contains("/Slack.app/")
}

func matches(_ p: AudioProcess) -> Bool {
    if p.pid == ownPID { return false }
    if !pids.isEmpty || appMatch != nil {
        if pids.contains(p.pid) { return true }
        if let m = appMatch?.lowercased() {
            return p.bundleID.lowercased().contains(m) || p.path.lowercased().contains(m)
        }
        return false
    }
    return isSlack(p)
}

func chooseOutput() throws -> OutputDevice {
    guard let outputMatch else { return try defaultOutputDevice() }
    let devices = try outputDevices()
    guard let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(outputMatch) }) else {
        fail("no output device matching '\(outputMatch)'. Devices: \(devices.map(\.name).joined(separator: ", "))")
    }
    return d
}

let targetName = !pids.isEmpty ? "pid \(pids.map(String.init).joined(separator: ","))" : (appMatch ?? "Slack")
let engine = TapEngine(params: params)
var tapped: [AudioObjectID] = []
var tappedOutput = ""
var stoppedSilent = false
var status = "starting"
let isTTY = isatty(STDOUT_FILENO) != 0
// Line-buffer stdout so a log file or pipe sees each line as it happens.
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ line: String) {
    if isTTY && !quiet { print("\r\u{1B}[K", terminator: "") }
    print(line)
}

func reconcile() {
    do {
        let procs = try audioProcesses().filter(matches)
        let ids = procs.map(\.id).sorted()
        let output = try chooseOutput()
        if ids == tapped && output.uid == tappedOutput && (engine.isRunning || ids.isEmpty || stoppedSilent) { return }
        stoppedSilent = false
        engine.stop()
        tapped = ids
        tappedOutput = output.uid
        if ids.isEmpty {
            status = "waiting for \(targetName) to use audio"
            log("No \(targetName) audio processes yet; waiting (join a huddle).")
            return
        }
        try engine.start(processes: ids, output: output)
        let who = procs.map { "\($0.pid)" }.joined(separator: ",")
        status = "\(targetName) → \(output.name)"
        log("Tapping \(targetName) (\(procs.count) process\(procs.count == 1 ? "" : "es"): \(who)) → \(output.name) @ \(Int(engine.sampleRate)) Hz")
    } catch {
        engine.stop()
        // Forget what we tapped so the next process or device change retries.
        tapped = []
        tappedOutput = ""
        status = "error"
        log("Could not start: \(error)")
        if let e = error as? CoreAudioError, e.what.contains("CreateProcessTap") {
            log("If macOS asked for permission, allow it in System Settings → Privacy & Security → Screen & System Audio Recording (\"System Audio Recording Only\"), then re-run.")
        }
    }
}

func meterBar(_ db: Float, width: Int = 20) -> String {
    let filled = Int(((db + 60) / 60 * Float(width)).rounded())
    let n = max(0, min(width, filled))
    return String(repeating: "█", count: n) + String(repeating: "·", count: width - n)
}

var lastFrames: UInt64 = 0
var silentTicks = 0
var meterTicks = 0
var logPeakIn: Float = -120
var logPeakOut: Float = -120

func drawMeter() {
    let m = leveler_take_meters(engine.state)
    guard engine.isRunning else { return }
    let inDB = 20 * log10(max(m.in_peak, 1e-6))
    let outDB = 20 * log10(max(m.out_peak, 1e-6))
    // Warn once if the tap runs but delivers nothing but zeros for a while
    // while the app reports it is playing: that is what a missing permission looks like.
    if m.frames != lastFrames && m.in_peak == 0 { silentTicks += 1 } else { silentTicks = 0 }
    lastFrames = m.frames
    if silentTicks >= 100 {
        silentTicks = 0
        let playing = (try? audioProcesses().filter(matches).contains(where: \.isPlaying)) ?? false
        if playing {
            // Most likely missing permission. The tap keeps the app muted, so
            // stop tapping and let its audio play unprocessed; the next
            // process or device change tries again.
            engine.stop()
            stoppedSilent = true
            status = "stopped: tap was silent"
            log("Tap received only silence for 10 s while \(targetName) was playing, so it stopped and \(targetName) plays unprocessed. Check System Settings → Privacy & Security → Screen & System Audio Recording for your terminal.")
            return
        }
    }
    guard !quiet else { return }
    if !isTTY {
        // Logging to a file or pipe: one line every two seconds while there's sound.
        meterTicks += 1
        logPeakIn = max(logPeakIn, inDB)
        logPeakOut = max(logPeakOut, outDB)
        if meterTicks % 20 == 0 {
            if logPeakIn > -100 {
                print(String(format: "%@ in %.1f dB, gain %+.1f dB, out %.1f dB",
                             engine.bypass ? "bypass" : "on", logPeakIn, m.gain_db, logPeakOut))
            }
            logPeakIn = -120
            logPeakOut = -120
        }
        return
    }
    let mode = engine.bypass ? "BYPASS" : "ON    "
    let gain = engine.bypass ? "   --  " : String(format: "%+5.1f dB", m.gain_db)
    let line = String(format: "\r\u{1B}[K[%@] in %@ %6.1f  gain %@  out %@ %6.1f",
                      mode, meterBar(inDB), inDB, gain, meterBar(outDB), outDB)
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

func runLive() {
    let queue = DispatchQueue.main
    var pending: DispatchWorkItem?
    func scheduleReconcile() {
        pending?.cancel()
        let item = DispatchWorkItem { reconcile() }
        pending = item
        queue.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    let listeners = [
        SystemListener(kAudioHardwarePropertyProcessObjectList, queue: queue, handler: scheduleReconcile),
        SystemListener(kAudioHardwarePropertyDefaultOutputDevice, queue: queue, handler: scheduleReconcile),
        SystemListener(kAudioHardwarePropertyDevices, queue: queue, handler: scheduleReconcile),
    ]

    func shutdown() {
        engine.stop()
        if isTTY && !quiet { print("") }
        print("Stopped; \(targetName) audio is back to normal.")
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        s.setEventHandler(handler: shutdown)
        s.resume()
        return s
    }

    Thread.detachNewThread {
        while let line = readLine() {
            let cmd = line.trimmingCharacters(in: .whitespaces).lowercased()
            DispatchQueue.main.async {
                if cmd == "q" || cmd == "quit" { shutdown() }
                engine.bypass.toggle()
                log(engine.bypass ? "Bypass: hearing \(targetName) unprocessed." : "Compressor on.")
            }
        }
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
    timer.setEventHandler(handler: drawMeter)
    timer.resume()

    reconcile()
    withExtendedLifetime((listeners, signals, timer)) { dispatchMain() }
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
