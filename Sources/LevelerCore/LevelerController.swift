import CoreAudio
import Foundation
@_exported import LevelerDSP

/// Which processes to tap.
public struct TapTarget {
    public let name: String
    public let matches: (AudioProcess) -> Bool

    public init(name: String, matches: @escaping (AudioProcess) -> Bool) {
        self.name = name
        self.matches = matches
    }

    public static let slack = TapTarget(name: "Slack") { p in
        p.bundleID.hasPrefix("com.tinyspeck.slackmacgap") || p.path.contains("/Slack.app/")
    }
}

/// Keeps a tap on the target's audio processes while active: starts it when
/// they appear, rebuilds it when they or the output device change, and backs
/// off when the tap delivers only silence. Use from the main queue only.
public final class LevelerController {
    public enum State: Equatable {
        case off
        case waiting
        case running(output: String)
        case retrying
        case error(String)
    }

    public let target: TapTarget
    public var params: leveler_params {
        didSet { engine.update(params: params) }
    }
    /// Preferred output device UID; falls back to the system default when
    /// nil or unplugged.
    public var outputUID: String? {
        didSet { if isActive { rebuild() } }
    }
    /// Output device name to match (CLI); must exist when set.
    public var outputNameMatch: String?
    public var bypass: Bool {
        get { engine.bypass }
        set { engine.bypass = newValue }
    }

    public private(set) var state: State = .off {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((State) -> Void)?
    public var onLog: ((String) -> Void)?
    /// Called every 100 ms while active with the meters since the last call.
    public var onMeters: ((leveler_meters) -> Void)?

    /// The engine, for diagnostics such as recording.
    public var tapEngine: TapEngine { engine }

    public private(set) var isActive = false
    public var sampleRate: Double { engine.sampleRate }

    private let engine: TapEngine
    private let ownPID = getpid()
    private var listeners: [SystemListener] = []
    private var timer: DispatchSourceTimer?
    private var pendingReconcile: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var tapped: [AudioObjectID] = []
    private var tappedOutput = ""
    private var stoppedSilent = false
    private var lastFrames: UInt64 = 0
    private var silentTicks = 0
    private var tapHeardAudio = false

    public init(target: TapTarget, params: leveler_params) {
        self.target = target
        self.params = params
        engine = TapEngine(params: params)
    }

    deinit { deactivate() }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        let queue = DispatchQueue.main
        let schedule: () -> Void = { [weak self] in self?.scheduleReconcile() }
        listeners = [
            SystemListener(kAudioHardwarePropertyProcessObjectList, queue: queue, handler: schedule),
            SystemListener(kAudioHardwarePropertyDefaultOutputDevice, queue: queue, handler: schedule),
            SystemListener(kAudioHardwarePropertyDevices, queue: queue, handler: schedule),
        ]
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        reconcile()
    }

    /// Stops tapping; the target's audio goes back to playing directly.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        listeners = []
        timer?.cancel()
        timer = nil
        pendingReconcile?.cancel()
        retry?.cancel()
        engine.stop()
        tapped = []
        tappedOutput = ""
        stoppedSilent = false
        state = .off
    }

    /// Tears down and rebuilds the tap, for a changed output choice.
    public func rebuild() {
        tapped = []
        tappedOutput = ""
        stoppedSilent = false
        reconcile()
    }

    private func scheduleReconcile() {
        pendingReconcile?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        pendingReconcile = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func matches(_ p: AudioProcess) -> Bool {
        p.pid != ownPID && target.matches(p)
    }

    private func chooseOutput() throws -> OutputDevice {
        if let outputUID, let d = try outputDevices().first(where: { $0.uid == outputUID }) {
            return d
        }
        if let outputNameMatch {
            let devices = try outputDevices()
            guard let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(outputNameMatch) }) else {
                throw NoSuchDevice(match: outputNameMatch, available: devices.map(\.name))
            }
            return d
        }
        return try defaultOutputDevice()
    }

    private func reconcile() {
        guard isActive else { return }
        do {
            let procs = try audioProcesses().filter(matches)
            let ids = procs.map(\.id).sorted()
            let output = try chooseOutput()
            if ids == tapped && output.uid == tappedOutput && (engine.isRunning || ids.isEmpty || stoppedSilent) { return }
            stoppedSilent = false
            retry?.cancel()
            engine.stop()
            tapped = ids
            tappedOutput = output.uid
            if ids.isEmpty {
                state = .waiting
                onLog?("No \(target.name) audio processes yet; waiting (join a huddle).")
                return
            }
            try engine.start(processes: ids, output: output)
            tapHeardAudio = false
            silentTicks = 0
            state = .running(output: output.name)
            let who = procs.map { "\($0.pid)" }.joined(separator: ",")
            onLog?("Tapping \(target.name) (\(procs.count) process\(procs.count == 1 ? "" : "es"): \(who)) → \(output.name) @ \(Int(engine.sampleRate)) Hz")
        } catch {
            engine.stop()
            // Forget what we tapped so the next process or device change retries.
            tapped = []
            tappedOutput = ""
            state = .error("\(error)")
            onLog?("Could not start: \(error)")
            if let e = error as? CoreAudioError, e.what.contains("CreateProcessTap") {
                onLog?("If macOS asked for permission, allow it in System Settings → Privacy & Security → Screen & System Audio Recording (\"System Audio Recording Only\").")
            }
        }
    }

    private func tick() {
        let m = leveler_take_meters(engine.state)
        guard engine.isRunning else { return }
        // A tap that has never delivered a sample while the app is playing is
        // either missing permission or hearing a huddle where nobody has
        // spoken yet; the samples can't tell which. Once audio has come
        // through, silence is just a quiet huddle.
        if m.in_peak > 0 { tapHeardAudio = true }
        if !tapHeardAudio && m.frames != lastFrames { silentTicks += 1 } else { silentTicks = 0 }
        lastFrames = m.frames
        if silentTicks >= 100 {
            silentTicks = 0
            if (try? audioProcesses().filter(matches).contains(where: \.isPlaying)) ?? false {
                backOffSilentTap()
                return
            }
        }
        onMeters?(m)
    }

    /// The tap keeps the app muted, so stop tapping and let its audio play
    /// unprocessed, then try again in 30 s (or sooner on a process or device
    /// change).
    private func backOffSilentTap() {
        engine.stop()
        stoppedSilent = true
        state = .retrying
        onLog?("Tap received only silence for 10 s while \(target.name) was playing, so \(target.name) plays unprocessed for now; retrying in 30 s. If this repeats while people are talking, allow audio recording in System Settings → Privacy & Security → Screen & System Audio Recording.")
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.stoppedSilent else { return }
            self.rebuild()
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }
}

public struct NoSuchDevice: Error, CustomStringConvertible {
    public let match: String
    public let available: [String]
    public var description: String {
        "no output device matching '\(match)'. Devices: \(available.joined(separator: ", "))"
    }
}
