import LevelerCore
import ServiceManagement
import SwiftUI

@main
struct HuddleLevelerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            Image(systemName: model.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Settings live in UserDefaults; the controller follows them.
final class AppModel: ObservableObject {
    private let defaults = UserDefaults.standard
    private let controller: LevelerController

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "enabled")
            if enabled { controller.activate() } else { controller.deactivate() }
        }
    }
    /// Hear Slack unprocessed, for comparison. Not saved.
    @Published var compare = false {
        didSet { controller.bypass = compare }
    }
    /// How hard talkers are evened out (level ratio, 1 = off).
    @Published var evenness: Double { didSet { saveParams() } }
    /// Level every talker is moved toward, dBFS.
    @Published var loudness: Double { didSet { saveParams() } }
    /// Treble cut for loud talkers, dB.
    @Published var soften: Double { didSet { saveParams() } }
    /// Output device UID, or "" for the system default.
    @Published var outputUID: String {
        didSet {
            defaults.set(outputUID, forKey: "outputUID")
            controller.outputUID = outputUID.isEmpty ? nil : outputUID
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { setLaunchAtLogin(launchAtLogin) }
    }

    @Published private(set) var state: LevelerController.State = .off
    @Published private(set) var talkerDB: Float = -120
    @Published private(set) var gainDB: Float = 0
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var loginError: String?

    static let defaultParams = leveler_default_params()

    init() {
        let d = UserDefaults.standard
        let p = Self.defaultParams
        d.register(defaults: [
            "enabled": true,
            "evenness": Double(p.level_ratio),
            "loudness": Double(p.target_db),
            "soften": Double(p.soften_db),
            "outputUID": "",
        ])
        enabled = d.bool(forKey: "enabled")
        evenness = d.double(forKey: "evenness")
        loudness = d.double(forKey: "loudness")
        soften = d.double(forKey: "soften")
        outputUID = d.string(forKey: "outputUID") ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled

        controller = LevelerController(target: .slack, params: Self.defaultParams)
        controller.params = currentParams()
        controller.outputUID = outputUID.isEmpty ? nil : outputUID
        controller.onStateChange = { [weak self] s in self?.state = s }
        controller.onMeters = { [weak self] m in
            guard let self else { return }
            // Only publish when something visible changes, so an idle menu
            // doesn't redraw ten times a second.
            let talker = (m.level_db * 2).rounded() / 2, gain = (m.gain_db * 2).rounded() / 2
            if talker != self.talkerDB { self.talkerDB = talker }
            if gain != self.gainDB { self.gainDB = gain }
        }
        controller.onLog = { line in NSLog("huddle-leveler: %@", line) }
        if enabled { controller.activate() }
        refreshDevices()
    }

    var iconName: String {
        switch state {
        case .off: return "waveform.slash"
        case .error: return "exclamationmark.triangle"
        case .running: return compare ? "waveform.path" : "waveform"
        case .waiting, .retrying: return "waveform"
        }
    }

    var statusText: String {
        switch state {
        case .off: return "Off: Slack plays normally"
        case .waiting: return "Waiting for a Slack huddle"
        case .running(let output): return compare ? "Hearing raw Slack on \(output)" : "Leveling Slack on \(output)"
        case .retrying: return "No audio from Slack yet; retrying shortly"
        case .error(let message): return message
        }
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func refreshDevices() {
        devices = (try? outputDevices()) ?? []
    }

    func resetToDefaults() {
        let p = Self.defaultParams
        evenness = Double(p.level_ratio)
        loudness = Double(p.target_db)
        soften = Double(p.soften_db)
    }

    private func currentParams() -> leveler_params {
        var p = Self.defaultParams
        p.level_ratio = Float(evenness)
        p.target_db = Float(loudness)
        p.soften_db = Float(soften)
        return p
    }

    private func saveParams() {
        defaults.set(evenness, forKey: "evenness")
        defaults.set(loudness, forKey: "loudness")
        defaults.set(soften, forKey: "soften")
        controller.params = currentParams()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Huddle Leveler").font(.headline)
                Spacer()
                Toggle("", isOn: $model.enabled).toggleStyle(.switch).labelsHidden()
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.isRunning && !model.compare {
                HStack(spacing: 16) {
                    Label(model.talkerDB > -100 ? String(format: "%.0f dB", model.talkerDB) : "—", systemImage: "person.wave.2")
                        .help("Level of whoever is talking")
                    Label(String(format: "%+.1f dB", model.gainDB), systemImage: model.gainDB < -0.5 ? "arrow.down" : (model.gainDB > 0.5 ? "arrow.up" : "equal"))
                        .help("How much they're being turned up or down")
                }
                .font(.callout.monospacedDigit())
            }

            Toggle("Compare: hear raw Slack", isOn: $model.compare)
                .disabled(!model.isRunning)

            Divider()

            SettingSlider(title: "Even out talkers", value: $model.evenness, range: 1...8,
                          label: model.evenness < 1.05 ? "Off" : String(format: "%.1f:1", model.evenness),
                          low: "Off", high: "Strong")
            SettingSlider(title: "Loudness", value: $model.loudness, range: -36...(-12),
                          label: String(format: "%.0f dB", model.loudness),
                          low: "Quieter", high: "Louder")
            SettingSlider(title: "Soften loud voices", value: $model.soften, range: 0...15,
                          label: model.soften < 0.5 ? "Off" : String(format: "%.0f dB", model.soften),
                          low: "Off", high: "Strong")

            Picker("Output", selection: $model.outputUID) {
                Text("System default").tag("")
                ForEach(model.devices, id: \.uid) { d in
                    Text(d.name).tag(d.uid)
                }
            }

            Divider()

            Toggle("Open at login", isOn: $model.launchAtLogin)
            if let e = model.loginError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Reset to defaults") { model.resetToDefaults() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshDevices() }
    }
}

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $value, in: range) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
