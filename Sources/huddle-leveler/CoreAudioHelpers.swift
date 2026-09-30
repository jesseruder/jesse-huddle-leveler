import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String {
        let be = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: be) { Array($0) }
        let fourcc = bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? " '\(String(bytes: bytes, encoding: .ascii)!)'" : ""
        return "\(what) failed: OSStatus \(status)\(fourcc)"
    }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T) throws -> T {
    var addr = address(selector, scope)
    var result = value
    var size = UInt32(MemoryLayout<T>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &result), "read property \(selector)")
    return result
}

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of _: T.Type) throws -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size), "size of property \(selector)")
    let count = Int(size) / MemoryLayout<T>.stride
    if count == 0 { return [] }
    let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
    defer { buffer.deallocate() }
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer), "read property \(selector)")
    return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
    var addr = address(selector, scope)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "read string property \(selector)")
    return (value?.takeRetainedValue() as String?) ?? ""
}

// MARK: - Processes

struct AudioProcess {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let path: String
    let isPlaying: Bool

    var displayName: String {
        if !bundleID.isEmpty { return bundleID }
        return (path as NSString).lastPathComponent
    }
}

func executablePath(of pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
}

func audioProcesses() throws -> [AudioProcess] {
    let ids = try getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                           of: AudioObjectID.self)
    return ids.compactMap { id in
        guard let pid = try? getValue(id, kAudioProcessPropertyPID, default: pid_t(-1)), pid > 0 else { return nil }
        let bundleID = (try? getString(id, kAudioProcessPropertyBundleID)) ?? ""
        let playing = ((try? getValue(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0) != 0
        return AudioProcess(id: id, pid: pid, bundleID: bundleID, path: executablePath(of: pid), isPlaying: playing)
    }
}

// MARK: - Devices

struct OutputDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
}

func outputDevices() throws -> [OutputDevice] {
    let ids = try getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    return ids.compactMap { id in
        guard let streams = try? getArray(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput,
                                          of: AudioStreamID.self), !streams.isEmpty,
              let uid = try? getString(id, kAudioDevicePropertyDeviceUID),
              let name = try? getString(id, kAudioObjectPropertyName) else { return nil }
        return OutputDevice(id: id, uid: uid, name: name)
    }
}

func defaultOutputDevice() throws -> OutputDevice {
    let id = try getValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                          default: AudioObjectID(kAudioObjectUnknown))
    return OutputDevice(id: id, uid: try getString(id, kAudioDevicePropertyDeviceUID),
                        name: (try? getString(id, kAudioObjectPropertyName)) ?? "?")
}

// MARK: - Listeners

/// Calls `handler` on `queue` whenever a property of the system object changes.
final class SystemListener {
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(_ selector: AudioObjectPropertySelector, queue: DispatchQueue, handler: @escaping () -> Void) {
        addr = address(selector)
        self.queue = queue
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }
}
