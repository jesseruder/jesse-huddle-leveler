import CoreAudio
import Foundation
import LevelerDSP

/// Taps a set of processes, mutes their direct output, and plays the tapped
/// mix through the compressor to one output device.
///
/// The tap and the output device are joined in a private aggregate device, so
/// a single IOProc receives the tapped audio as input and writes the device's
/// output in the same callback. Because the tap uses `.mutedWhenTapped`, the
/// apps' original audio comes back on its own if this process dies.
public final class TapEngine {
    public let state: OpaquePointer
    private var params: leveler_params
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    public private(set) var sampleRate: Double = 0
    public private(set) var isRunning = false

    public init(params: leveler_params) {
        self.params = params
        state = leveler_create()
    }

    deinit {
        stop()
        leveler_destroy(state)
    }

    /// Changes settings without interrupting audio.
    public func update(params: leveler_params) {
        self.params = params
        leveler_set_params(state, params)
    }

    public var bypass: Bool {
        get { leveler_get_bypass(state) != 0 }
        set { leveler_set_bypass(state, newValue ? 1 : 0) }
    }

    public func start(processes: [AudioObjectID], output: OutputDevice) throws {
        guard stop() else { throw TeardownFailed() }
        do {
            try createTap(processes: processes)
            try createAggregate(output: output)
            try checkFormats()
            sampleRate = try getValue(aggregateID, kAudioDevicePropertyNominalSampleRate, default: Float64(48000))
            leveler_init(state, params, Float(sampleRate))
            try check(leveler_create_ioproc(aggregateID, state, &procID), "AudioDeviceCreateIOProcID")
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Tears everything down. An object whose destroy call fails keeps its ID
    /// so the next stop() retries it; start() refuses to run until it's gone.
    @discardableResult
    public func stop() -> Bool {
        isRunning = false
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            if report(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID") {
                self.procID = nil
            }
        }
        if aggregateID != kAudioObjectUnknown && procID == nil {
            if report(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice") {
                aggregateID = AudioObjectID(kAudioObjectUnknown)
            }
        }
        if tapID != kAudioObjectUnknown && aggregateID == kAudioObjectUnknown {
            if report(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap") {
                tapID = AudioObjectID(kAudioObjectUnknown)
            }
        }
        return procID == nil && aggregateID == kAudioObjectUnknown && tapID == kAudioObjectUnknown
    }

    private func report(_ status: OSStatus, _ what: String) -> Bool {
        if status == noErr || status == kAudioHardwareBadObjectError { return true }
        FileHandle.standardError.write("huddle-leveler: \(CoreAudioError(what: what, status: status))\n".data(using: .utf8)!)
        return false
    }

    /// The IOProc only understands 32-bit float PCM, so refuse anything else
    /// rather than misread the buffers.
    private func checkFormats() throws {
        for scope in [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput] {
            let streams = try getArray(aggregateID, kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self)
            for stream in streams {
                let f = try getValue(stream, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
                let isFloat32 = f.mFormatID == kAudioFormatLinearPCM
                    && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
                    && f.mBitsPerChannel == 32
                if !isFloat32 {
                    throw UnsupportedFormat(description: "stream \(stream) is not 32-bit float PCM (format \(f.mFormatID), flags \(f.mFormatFlags), \(f.mBitsPerChannel) bits)")
                }
            }
        }
    }

    private var tapUUID = UUID()

    private func createTap(processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "huddle-leveler"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
    }

    private func createAggregate(output: OutputDevice) throws {
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "huddle-leveler",
            kAudioAggregateDeviceUIDKey: "huddle-leveler-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID),
                  "AudioHardwareCreateAggregateDevice")
    }
}

struct UnsupportedFormat: Error, CustomStringConvertible {
    let description: String
}

struct TeardownFailed: Error, CustomStringConvertible {
    var description: String { "the previous tap could not be torn down" }
}
