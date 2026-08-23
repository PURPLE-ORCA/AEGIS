import AVFoundation
import XCTest
@testable import Aegis

final class SoundProfileTests: XCTestCase {
    func testProfessionalProfilesHaveStableNames() {
        XCTAssertEqual(
            SoundProfile.allCases.map(\.displayName),
            ["Quiet Glass", "Soft Relay", "Deep Signal", "Yamete Kudasai"]
        )
    }

    func testYameteKudasaiProfileHasReadableVoiceCues() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/sounds/yamete-kudasai", isDirectory: true)

        for name in ["yamete-kudasai", "brief-action"] {
            let file = try AVAudioFile(
                forReading: resources.appendingPathComponent("\(name).aiff")
            )
            XCTAssertGreaterThan(file.length, 0, name)
            XCTAssertEqual(file.processingFormat.channelCount, 1, name)
        }
    }

    func testYameteKudasaiUsesBriefClipOnlyForBriefActions() {
        let profile = SoundProfile.yameteKudasai

        XCTAssertEqual(profile.bundledSoundName(for: .sessionStart), "brief-action")
        XCTAssertEqual(profile.bundledSoundName(for: .toolUse), "brief-action")

        for event in SoundEvent.allCases where event != .sessionStart && event != .toolUse {
            XCTAssertEqual(profile.bundledSoundName(for: event), "yamete-kudasai", event.rawValue)
        }
    }

    func testEventsMapToCompletionAttentionAndFailureCues() {
        XCTAssertEqual(SoundEvent.completion.cue, .completion)
        XCTAssertEqual(SoundEvent.sessionEnd.cue, .completion)
        XCTAssertEqual(SoundEvent.approvalGranted.cue, .completion)

        XCTAssertEqual(SoundEvent.approvalNeeded.cue, .attention)
        XCTAssertEqual(SoundEvent.sessionStart.cue, .attention)
        XCTAssertEqual(SoundEvent.toolUse.cue, .attention)

        XCTAssertEqual(SoundEvent.error.cue, .failure)
        XCTAssertEqual(SoundEvent.approvalDenied.cue, .failure)
    }

    func testEveryProfileGeneratesThreeDistinctBoundedCues() throws {
        for profile in SoundProfile.allCases {
            let synthesizer = SoundSynthesizer(profile: profile)
            let buffers = try [SoundEvent.completion, .approvalNeeded, .error].map {
                try XCTUnwrap(synthesizer.generateSound(for: $0))
            }

            XCTAssertEqual(Set(buffers.map(\.frameLength)).count, 3, profile.displayName)
            for buffer in buffers {
                XCTAssertGreaterThan(buffer.frameLength, 0)
                XCTAssertLessThanOrEqual(peakAmplitude(of: buffer), 0.24)
                XCTAssertGreaterThan(peakAmplitude(of: buffer), 0.01)
                XCTAssertEqual(try firstSample(in: buffer), 0, accuracy: 0.000_001)
                XCTAssertEqual(try lastSample(in: buffer), 0, accuracy: 0.001)
            }
        }
    }

    func testProfilesProduceDifferentCompletionContours() throws {
        let signatures = try SoundProfile.allCases.map { profile in
            let buffer = try XCTUnwrap(
                SoundSynthesizer(profile: profile).generateSound(for: .completion)
            )
            return Int(meanAbsoluteAmplitude(of: buffer) * 1_000_000)
        }

        XCTAssertEqual(Set(signatures).count, SoundProfile.allCases.count)
    }

    private func peakAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        return (0..<Int(buffer.frameLength)).reduce(0) { peak, frame in
            max(peak, abs(samples[frame]))
        }
    }

    private func meanAbsoluteAmplitude(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let total = (0..<Int(buffer.frameLength)).reduce(Float.zero) { sum, frame in
            sum + abs(samples[frame])
        }
        return total / Float(buffer.frameLength)
    }

    private func firstSample(in buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return samples[0]
    }

    private func lastSample(in buffer: AVAudioPCMBuffer) throws -> Float {
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        return samples[Int(buffer.frameLength) - 1]
    }
}
