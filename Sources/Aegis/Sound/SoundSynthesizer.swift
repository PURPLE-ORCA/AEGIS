import AVFoundation
import Foundation

enum SoundProfile: String, CaseIterable, Identifiable, Hashable {
    case quietGlass = "quiet-glass"
    case softRelay = "soft-relay"
    case deepSignal = "deep-signal"
    case yameteKudasai = "yamete-kudasai"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quietGlass: return "Quiet Glass"
        case .softRelay: return "Soft Relay"
        case .deepSignal: return "Deep Signal"
        case .yameteKudasai: return "Yamete Kudasai"
        }
    }

    var blurb: String {
        switch self {
        case .quietGlass:
            return "Clear, airy cues with a light upper register."
        case .softRelay:
            return "Warm, rounded cues designed for long work sessions."
        case .deepSignal:
            return "Low, deliberate cues with a measured finish."
        case .yameteKudasai:
            return "Unhinged anime reactions for every agent state."
        }
    }

    var bundledSoundSubdirectory: String? {
        switch self {
        case .yameteKudasai:
            return "sounds/yamete-kudasai"
        case .quietGlass, .softRelay, .deepSignal:
            return nil
        }
    }

    func bundledSoundName(for event: SoundEvent) -> String? {
        guard self == .yameteKudasai else { return nil }

        switch event {
        case .sessionStart, .toolUse:
            return "brief-action"
        case .sessionEnd, .completion, .error,
             .approvalNeeded, .approvalGranted, .approvalDenied:
            return "yamete-kudasai"
        }
    }

    var previewEvents: [SoundEvent] {
        switch self {
        case .yameteKudasai:
            return [.completion, .sessionStart, .error]
        case .quietGlass, .softRelay, .deepSignal:
            return [.completion, .approvalNeeded, .error]
        }
    }
}

enum SoundCue: String, Equatable {
    case completion
    case attention
    case failure
}

extension SoundEvent {
    var cue: SoundCue {
        switch self {
        case .sessionEnd, .completion, .approvalGranted:
            return .completion
        case .sessionStart, .toolUse, .approvalNeeded:
            return .attention
        case .error, .approvalDenied:
            return .failure
        }
    }
}

/// Generates short notification tones from profile-owned oscillator, pitch,
/// envelope, and gain parameters.
struct SoundSynthesizer {
    private let sampleRate: Double = 44_100
    let profile: SoundProfile

    init(profile: SoundProfile = .quietGlass) {
        self.profile = profile
    }

    func generateSound(for event: SoundEvent) -> AVAudioPCMBuffer? {
        render(preset(for: event.cue))
    }

    private struct Voice {
        let frequency: Double
        let start: Double
        let duration: Double
        let gain: Double
        let brightness: Double

        init(_ frequency: Double, start: Double, duration: Double, gain: Double, brightness: Double) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
            self.gain = gain
            self.brightness = brightness
        }
    }

    private struct Envelope {
        let attack: Double
        let release: Double
        let decay: Double
    }

    private struct CuePreset {
        let duration: Double
        let voices: [Voice]
        let envelope: Envelope
    }

    private func preset(for cue: SoundCue) -> CuePreset {
        switch (profile, cue) {
        case (.quietGlass, .completion):
            return CuePreset(
                duration: 0.46,
                voices: [
                    Voice(880.00, start: 0.00, duration: 0.34, gain: 0.105, brightness: 0.55),
                    Voice(1108.73, start: 0.075, duration: 0.34, gain: 0.085, brightness: 0.45),
                ],
                envelope: Envelope(attack: 0.012, release: 0.08, decay: 2.4)
            )
        case (.quietGlass, .attention):
            return CuePreset(
                duration: 0.40,
                voices: [
                    Voice(659.25, start: 0.00, duration: 0.26, gain: 0.080, brightness: 0.28),
                    Voice(880.00, start: 0.11, duration: 0.25, gain: 0.070, brightness: 0.25),
                ],
                envelope: Envelope(attack: 0.012, release: 0.08, decay: 2.4)
            )
        case (.quietGlass, .failure):
            return CuePreset(
                duration: 0.32,
                voices: [
                    Voice(349.23, start: 0.00, duration: 0.24, gain: 0.080, brightness: 0.12),
                    Voice(293.66, start: 0.07, duration: 0.22, gain: 0.065, brightness: 0.10),
                ],
                envelope: Envelope(attack: 0.012, release: 0.08, decay: 2.4)
            )

        case (.softRelay, .completion):
            return CuePreset(
                duration: 0.46,
                voices: [
                    Voice(523.25, start: 0.00, duration: 0.36, gain: 0.080, brightness: 0.20),
                    Voice(659.25, start: 0.09, duration: 0.32, gain: 0.060, brightness: 0.16),
                ],
                envelope: Envelope(attack: 0.020, release: 0.12, decay: 1.8)
            )
        case (.softRelay, .attention):
            return CuePreset(
                duration: 0.40,
                voices: [
                    Voice(440.00, start: 0.00, duration: 0.30, gain: 0.070, brightness: 0.16),
                    Voice(587.33, start: 0.11, duration: 0.25, gain: 0.052, brightness: 0.12),
                ],
                envelope: Envelope(attack: 0.020, release: 0.12, decay: 1.8)
            )
        case (.softRelay, .failure):
            return CuePreset(
                duration: 0.32,
                voices: [
                    Voice(392.00, start: 0.00, duration: 0.25, gain: 0.068, brightness: 0.10),
                    Voice(349.23, start: 0.07, duration: 0.22, gain: 0.052, brightness: 0.08),
                ],
                envelope: Envelope(attack: 0.020, release: 0.12, decay: 1.8)
            )

        case (.deepSignal, .completion):
            return CuePreset(
                duration: 0.46,
                voices: [
                    Voice(261.63, start: 0.00, duration: 0.37, gain: 0.090, brightness: 0.18),
                    Voice(392.00, start: 0.10, duration: 0.31, gain: 0.062, brightness: 0.14),
                ],
                envelope: Envelope(attack: 0.026, release: 0.16, decay: 1.5)
            )
        case (.deepSignal, .attention):
            return CuePreset(
                duration: 0.40,
                voices: [
                    Voice(329.63, start: 0.00, duration: 0.30, gain: 0.082, brightness: 0.14),
                    Voice(493.88, start: 0.11, duration: 0.24, gain: 0.056, brightness: 0.11),
                ],
                envelope: Envelope(attack: 0.026, release: 0.16, decay: 1.5)
            )
        case (.deepSignal, .failure):
            return CuePreset(
                duration: 0.32,
                voices: [
                    Voice(220.00, start: 0.00, duration: 0.25, gain: 0.085, brightness: 0.08),
                    Voice(164.81, start: 0.07, duration: 0.21, gain: 0.060, brightness: 0.06),
                ],
                envelope: Envelope(attack: 0.026, release: 0.16, decay: 1.5)
            )

        // The bundled voice clips are the primary cues for this profile. These
        // light fallback tones keep notifications functional if an app bundle
        // is copied without its resources.
        case (.yameteKudasai, .completion):
            return CuePreset(
                duration: 0.50,
                voices: [
                    Voice(783.99, start: 0.00, duration: 0.28, gain: 0.090, brightness: 0.38),
                    Voice(1046.50, start: 0.10, duration: 0.34, gain: 0.080, brightness: 0.42),
                ],
                envelope: Envelope(attack: 0.014, release: 0.10, decay: 1.9)
            )
        case (.yameteKudasai, .attention):
            return CuePreset(
                duration: 0.44,
                voices: [
                    Voice(698.46, start: 0.00, duration: 0.27, gain: 0.085, brightness: 0.34),
                    Voice(932.33, start: 0.12, duration: 0.27, gain: 0.075, brightness: 0.36),
                ],
                envelope: Envelope(attack: 0.014, release: 0.10, decay: 1.9)
            )
        case (.yameteKudasai, .failure):
            return CuePreset(
                duration: 0.36,
                voices: [
                    Voice(587.33, start: 0.00, duration: 0.25, gain: 0.088, brightness: 0.30),
                    Voice(440.00, start: 0.08, duration: 0.24, gain: 0.070, brightness: 0.24),
                ],
                envelope: Envelope(attack: 0.014, release: 0.10, decay: 1.9)
            )
        }
    }

    private func render(_ preset: CuePreset) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * preset.duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            var mixed = 0.0

            for voice in preset.voices {
                let localTime = time - voice.start
                guard localTime >= 0, localTime < voice.duration else { continue }

                let fundamental = sin(2 * .pi * voice.frequency * localTime)
                let second = sin(2 * .pi * voice.frequency * 2.01 * localTime) * voice.brightness * 0.24
                let fourth = sin(2 * .pi * voice.frequency * 3.98 * localTime) * voice.brightness * 0.08
                let normalization = 1 + voice.brightness * 0.32
                mixed += ((fundamental + second + fourth) / normalization)
                    * voice.gain
                    * envelope(at: localTime, duration: voice.duration, preset: preset.envelope)
            }

            samples[frame] = Float(max(-0.24, min(0.24, mixed)))
        }
        return buffer
    }

    private func envelope(at time: Double, duration: Double, preset: Envelope) -> Double {
        let attack = min(preset.attack, duration * 0.15)
        let release = min(preset.release, duration * 0.35)
        let attackGain = min(1, time / attack)
        let releaseGain = time < duration - release ? 1 : max(0, (duration - time) / release)
        let decay = exp(-preset.decay * time / duration)
        return attackGain * releaseGain * decay
    }
}
