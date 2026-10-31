import CloudDiskKit
import XCTest
@testable import CloudDisk

/// The sentences the file browser shows after a "keep offline" request.
///
/// Only the wording is tested here, but the wording is the part the user acts on: five different system
/// answers have to stay distinguishable, and two of them must not read as a promise that was kept.
@MainActor
final class FileBrowserSentenceTests: XCTestCase {

    private func sentence(_ effect: PinOutcome.Effect, pinned: Bool = true) -> String {
        FileBrowser.sentence(for: PinOutcome(pinned: pinned, effect: effect), name: "clip.mp4")
    }

    func testEachEffectHasItsOwnSentence() {
        let all: [PinOutcome.Effect] = [
            .downloadScheduled, .downloadDeferred, .policyPublished,
            .refused("no room"), .systemUnavailable("no domain"),
        ]
        let texts = all.map { sentence($0) }
        XCTAssertEqual(Set(texts).count, all.count, "two different answers share a sentence")
        for text in texts {
            XCTAssertTrue(text.contains("clip.mp4"), "\(text) does not say which file it is about")
        }
    }

    func testTheTwoRefusalsDoNotReadAsSuccess() {
        let refused = sentence(.refused("the disk is full"))
        XCTAssertFalse(refused.contains("will stay on this Mac"))
        XCTAssertTrue(refused.contains("the disk is full"), "the system's own reason is dropped")

        let unavailable = sentence(.systemUnavailable("its Finder location is not mounted"))
        XCTAssertFalse(unavailable.contains("will stay on this Mac"))
        XCTAssertTrue(unavailable.contains("its Finder location is not mounted"))
    }

    /// The browser picks `.done` or `.refused` from `succeeded`, so a sentence and that flag disagreeing
    /// would show a green checkmark over a failure.
    func testTheSentencesAndTheSucceededFlagAgree() {
        let promising: [PinOutcome.Effect] = [.downloadScheduled, .downloadDeferred, .policyPublished]
        for effect in promising {
            let outcome = PinOutcome(pinned: true, effect: effect)
            XCTAssertTrue(outcome.succeeded, "\(effect) is a kept promise but reports failure")
        }
        for effect in [PinOutcome.Effect.refused("x"), .systemUnavailable("x")] {
            let outcome = PinOutcome(pinned: true, effect: effect)
            XCTAssertFalse(outcome.succeeded, "\(effect) is not a kept promise but reports success")
        }
    }

    func testUnpinningSaysTheBytesMayGoAwayRatherThanThatTheyStayed() {
        let text = sentence(.policyPublished, pinned: false)
        XCTAssertTrue(text.contains("freed"), text)
        XCTAssertFalse(text.contains("downloading"), text)
    }
}
