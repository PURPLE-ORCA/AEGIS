import CoreAudio
import Combine
import Foundation

struct DictationMicrophone: Identifiable, Equatable {
    let id: String
    let deviceID: AudioDeviceID
    let name: String
    let builtIn: Bool

    static func resolve(preference: String, devices: [Self]) -> Self? {
        devices.first { $0.id == preference } ?? devices.first { $0.builtIn } ?? devices.first
    }

    static func available() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { memory.deallocate() }
            guard AudioObjectGetPropertyData(id, &input, 0, nil, &bytes, memory) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.contains(where: { $0.mNumberChannels > 0 }) else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, &value) == noErr else { return nil }
                return value?.takeRetainedValue() as String?
            }
            var transport: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &property, 0, nil, &length, &transport)
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return Self(id: uid, deviceID: id, name: name, builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

@MainActor
final class DictationMicrophoneMonitor: ObservableObject {
    static let shared = DictationMicrophoneMonitor()
    @Published private(set) var devices: [DictationMicrophone] = []
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        listener = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if let listener {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        refresh()
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }

    func refresh() {
        Task {
            let result = await Task.detached { DictationMicrophone.available() }.value
            devices = result
        }
    }

    func status(preference: String) -> String {
        guard let active = DictationMicrophone.resolve(preference: preference, devices: devices) else {
            return "No microphone is available. Connect a microphone to dictate."
        }
        if !preference.isEmpty && !devices.contains(where: { $0.id == preference }) {
            return "Selected microphone is disconnected. Using \(active.name) until it reconnects."
        }
        return "Using \(active.name)"
    }
}

actor DictationAudio {
    private let recorder = HermesAudioRecorder()
    func start(device: AudioDeviceID, level: @escaping (Double) -> Void, failure: @escaping () -> Void) throws {
        _ = try recorder.start(deviceID: device, levelHandler: level, failureHandler: failure)
    }
    func stop() -> URL? { recorder.stop() }
    func cancel() { recorder.cancel() }
    func removeRecording() { recorder.removeRecording() }
}
