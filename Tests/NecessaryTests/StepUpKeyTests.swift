// When the app replaces a step-up key its options do not accept (replacesStepUpKey). A known
// installation's registration never binds an offered key, so replacing the key there would orphan
// the one the backend holds.
import XCTest
@testable import Necessary

private func key(mode: String = "windowed", created: Bool = false) -> StepUpKeyMetadata {
    StepUpKeyMetadata(
        publicKey: ["kty": "EC", "crv": "P-256", "alg": "ES256", "x": "x", "y": "y"], factor: "passcode", mode: mode,
        windowSeconds: mode == "windowed" ? 30 : 0, securityLevel: "secure_enclave", hardwareBacked: true,
        created: created)
}

private let perUse = StepUpOptions()

final class StepUpKeyTests: XCTestCase {
    func testAKnownInstallationKeepsAKeyTheOptionsWantMoreOf() {
        XCTAssertFalse(replacesStepUpKey(key(), perUse, replaceMismatched: false, knownInstallation: true))
    }

    func testAReenrolmentReplacesItAndBindsTheNewOne() {
        XCTAssertTrue(replacesStepUpKey(key(), perUse, replaceMismatched: true, knownInstallation: true))
    }

    func testAnInstallationsFirstRegistrationReplacesIt() {
        XCTAssertTrue(replacesStepUpKey(key(), perUse, replaceMismatched: false, knownInstallation: false))
    }

    func testAKeyJustMadeOrOneTheOptionsAcceptIsNeverReplaced() {
        for known in [true, false] {
            XCTAssertFalse(replacesStepUpKey(key(created: true), perUse, replaceMismatched: true, knownInstallation: known))
            XCTAssertFalse(replacesStepUpKey(key(mode: "per_use"), perUse, replaceMismatched: true, knownInstallation: known))
        }
    }
}
