import XCTest
@testable import Aegis

final class SoundEngineLifecycleTests: XCTestCase {
    func testInitializationIsStopped() {
        let policy = AudioEngineLifecyclePolicy()

        XCTAssertEqual(policy.state, .stopped)
        XCTAssertEqual(policy.pendingPlaybackCount, 0)
    }

    func testPlaybackStartsOnceAndReusesRunningGeneration() {
        var policy = AudioEngineLifecyclePolicy()

        let first = policy.requestPlayback()
        let second = policy.requestPlayback()

        XCTAssertTrue(first.shouldStartEngine)
        XCTAssertFalse(second.shouldStartEngine)
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(policy.pendingPlaybackCount, 2)
    }

    func testTeardownWaitsForEveryScheduledBufferToFinish() {
        var policy = AudioEngineLifecyclePolicy()
        let generation = policy.requestPlayback().generation
        _ = policy.requestPlayback()

        XCTAssertFalse(policy.playbackFinished(generation: generation))
        XCTAssertTrue(policy.playbackFinished(generation: generation))
        XCTAssertEqual(policy.state, .idleTeardownPending(generation: generation))
        XCTAssertTrue(policy.idleDeadlineReached(generation: generation))
        XCTAssertEqual(policy.state, .stopped)
    }

    func testNewPlaybackCancelsPendingTeardownByReturningToRunning() {
        var policy = AudioEngineLifecyclePolicy()
        let first = policy.requestPlayback()
        XCTAssertTrue(policy.playbackFinished(generation: first.generation))

        let second = policy.requestPlayback()

        XCTAssertFalse(second.shouldStartEngine)
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertEqual(policy.state, .running(generation: first.generation))
        XCTAssertFalse(policy.idleDeadlineReached(generation: first.generation))
    }

    func testDisablingStopsImmediatelyAndInvalidatesOldCallbacks() {
        var policy = AudioEngineLifecyclePolicy()
        let request = policy.requestPlayback()

        XCTAssertTrue(policy.stop())
        XCTAssertEqual(policy.state, .stopped)
        XCTAssertEqual(policy.pendingPlaybackCount, 0)
        XCTAssertFalse(policy.playbackFinished(generation: request.generation))
        XCTAssertFalse(policy.stop())
    }

    func testEnablingAloneDoesNotRequestPlayback() {
        let policy = AudioEngineLifecyclePolicy()

        XCTAssertEqual(policy.state, .stopped)
    }

    func testPreviewCanUseTheSamePlaybackRequestWhileGloballyDisabled() {
        var policy = AudioEngineLifecyclePolicy()

        let request = policy.requestPlayback()

        XCTAssertTrue(request.shouldStartEngine)
        XCTAssertEqual(policy.state, .running(generation: request.generation))
    }

    func testFailedStartCanBeRetried() {
        var policy = AudioEngineLifecyclePolicy()
        let failed = policy.requestPlayback()
        policy.startFailed(generation: failed.generation)

        let retry = policy.requestPlayback()

        XCTAssertEqual(policy.state, .running(generation: retry.generation))
        XCTAssertTrue(retry.shouldStartEngine)
        XCTAssertNotEqual(retry.generation, failed.generation)
    }
}
