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
final class TapEngine {
    let state: OpaquePointer
    private let params: leveler_params
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 0
    private(set) var isRunning = false

    init(params: leveler_params) {
        self.params = params
        state = leveler_create()
    }

    deinit {
        stop()
        leveler_destroy(state)
    }

    var bypass: Bool {
        get { leveler_get_bypass(state) != 0 }
        set { leveler_set_bypass(state, newValue ? 1 : 0) }
    }

    func start(processes: [AudioObjectID], output: OutputDevice) throws {
        stop()
        do {
            try createTap(processes: processes)
            try createAggregate(output: output)
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

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
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
