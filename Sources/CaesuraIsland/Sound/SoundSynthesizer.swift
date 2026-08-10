import AVFoundation
import Foundation

/// Generates short, restrained notification tones from layered sine partials.
/// Smooth envelopes avoid clicks; low gain leaves headroom when tones overlap.
struct SoundSynthesizer {
    private let sampleRate: Double = 44_100

    func generateSound(for event: SoundEvent) -> AVAudioPCMBuffer? {
        switch event {
        case .sessionStart:
            return render(duration: 0.30, voices: [
                Voice(523.25, start: 0.00, duration: 0.24, gain: 0.075, brightness: 0.30),
                Voice(659.25, start: 0.06, duration: 0.22, gain: 0.055, brightness: 0.25),
            ])
        case .sessionEnd:
            return render(duration: 0.28, voices: [
                Voice(440.00, start: 0.00, duration: 0.25, gain: 0.075, brightness: 0.22),
            ])
        case .toolUse:
            return render(duration: 0.10, voices: [
                Voice(720.00, start: 0.00, duration: 0.08, gain: 0.035, brightness: 0.15),
            ])
        case .completion:
            return render(duration: 0.46, voices: [
                Voice(880.00, start: 0.00, duration: 0.34, gain: 0.105, brightness: 0.55),
                Voice(1108.73, start: 0.075, duration: 0.34, gain: 0.085, brightness: 0.45),
            ])
        case .error:
            return render(duration: 0.32, voices: [
                Voice(349.23, start: 0.00, duration: 0.24, gain: 0.080, brightness: 0.12),
                Voice(293.66, start: 0.07, duration: 0.22, gain: 0.065, brightness: 0.10),
            ])
        case .approvalNeeded:
            return render(duration: 0.40, voices: [
                Voice(659.25, start: 0.00, duration: 0.26, gain: 0.080, brightness: 0.28),
                Voice(880.00, start: 0.11, duration: 0.25, gain: 0.070, brightness: 0.25),
            ])
        case .approvalGranted:
            return render(duration: 0.28, voices: [
                Voice(783.99, start: 0.00, duration: 0.18, gain: 0.075, brightness: 0.28),
                Voice(1046.50, start: 0.045, duration: 0.20, gain: 0.060, brightness: 0.22),
            ])
        case .approvalDenied:
            return render(duration: 0.24, voices: [
                Voice(293.66, start: 0.00, duration: 0.21, gain: 0.075, brightness: 0.10),
            ])
        }
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

    private func render(duration: Double, voices: [Voice]) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            var mixed = 0.0

            for voice in voices {
                let localTime = time - voice.start
                guard localTime >= 0, localTime < voice.duration else { continue }

                let fundamental = sin(2 * .pi * voice.frequency * localTime)
                let second = sin(2 * .pi * voice.frequency * 2.01 * localTime) * voice.brightness * 0.24
                let fourth = sin(2 * .pi * voice.frequency * 3.98 * localTime) * voice.brightness * 0.08
                let normalization = 1 + voice.brightness * 0.32
                mixed += ((fundamental + second + fourth) / normalization)
                    * voice.gain
                    * envelope(at: localTime, duration: voice.duration)
            }

            samples[frame] = Float(max(-0.24, min(0.24, mixed)))
        }
        return buffer
    }

    private func envelope(at time: Double, duration: Double) -> Double {
        let attack = min(0.012, duration * 0.15)
        let release = min(0.08, duration * 0.35)
        let attackGain = min(1, time / attack)
        let releaseGain = time < duration - release ? 1 : max(0, (duration - time) / release)
        let decay = exp(-2.4 * time / duration)
        return attackGain * releaseGain * decay
    }
}
