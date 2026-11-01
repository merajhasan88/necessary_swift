// The reinstall hint's bytes: what a backend keys and stores to link reinstalls, so a phone's hint must
// not change when the SDK's code does. The digest was computed apart, by Python's hashlib.
import XCTest
@testable import Necessary

@MainActor
final class ReinstallHintTests: XCTestCase {
    func testTheIdentifierForVendorInLowerCase() async {
        let hint = await ReinstallHintReader(identifier: { "6F0C2A1E-7B3D-4C5E-9F8A-1B2C3D4E5F60" }).read()
        XCTAssertEqual(hint?.kind, "idfv_sha256")
        XCTAssertEqual(hint?.value, "a67ac309e7a6b8cac7fbf58e8d964b07bd525408624d1957f3a8fe7c670461e5")
    }

    func testNoIdentifierOrAnotherPlatformNoHint() async {
        let empty = await ReinstallHintReader(identifier: { "" }).read()
        XCTAssertNil(empty)
        let none = await ReinstallHintReader(identifier: { nil }).read()
        XCTAssertNil(none)
        let other = await ReinstallHintReader(platform: "linux", identifier: { "6f0c2a1e-7b3d-4c5e-9f8a-1b2c3d4e5f60" }).read()
        XCTAssertNil(other)
    }
}
