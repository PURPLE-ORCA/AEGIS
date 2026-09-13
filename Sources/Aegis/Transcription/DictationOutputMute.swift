import CoreAudio
import Foundation

@MainActor
final class DictationOutputMute {
    private var changedDevices = Set<AudioDeviceID>()
    private let devices: () throws -> [AudioDeviceID]
    private let readMute: (AudioDeviceID) throws -> Bool
    private let writeMute: (AudioDeviceID, Bool) throws -> Void

    init(devices: @escaping () throws -> [AudioDeviceID] = DictationOutputMute.outputDevices,
         readMute: @escaping (AudioDeviceID) throws -> Bool = DictationOutputMute.isMuted,
         writeMute: @escaping (AudioDeviceID, Bool) throws -> Void = DictationOutputMute.setMuted) {
        self.devices = devices
        self.readMute = readMute
        self.writeMute = writeMute
    }

    func mute() throws {
        do {
            // ponytail: capture current output routes; add route tracking if speaker switching during recording is needed.
            for device in Set(try devices()) where !changedDevices.contains(device) {
                guard try !readMute(device) else { continue }
                try writeMute(device, true)
                changedDevices.insert(device)
            }
        } catch {
            restore()
            throw error
        }
    }

    @discardableResult
    func restore() -> Bool {
        for device in changedDevices {
            do {
                try writeMute(device, false)
                changedDevices.remove(device)
            } catch {
                Log.error("Could not restore dictation output mute device=\(device): \(error.localizedDescription)")
            }
        }
        return changedDevices.isEmpty
    }

    nonisolated private static func outputDevices() throws -> [AudioDeviceID] {
        try [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice].map { selector in
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                  device != kAudioObjectUnknown else {
                throw DictationFailure(message: "Could not find the sound output to mute.")
            }
            return device
        }
    }

    nonisolated private static func isMuted(_ device: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            throw DictationFailure(message: "This sound output does not support automatic muting. Turn off Mute while recording to continue.")
        }
        return value != 0
    }

    nonisolated private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) throws {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
            throw DictationFailure(message: "Could not change the sound output mute state. Check your sound settings.")
        }
    }
}
