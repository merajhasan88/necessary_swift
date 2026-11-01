// The report-size rule: a report a backend would refuse for its size is never sent. The lists the
// contract lets a collector shorten are halved, and say truncated, until it fits; anything else is an
// error naming the limit -- nothing is cut silently.
import XCTest
@testable import Necessary

private func report(_ probes: JSONObject) -> JSONObject {
    ["challenge_id": "c", "challenge_nonce": "n", "installation_id": "i", "platform": "ios", "collector_version": 8,
     "collected_at": 1, "probe_results": .object(probes), "enabled_measurements": ["accessibility"], "version": 1]
}

private func bytes(_ report: JSONObject) -> Int { report.encodedJSON.utf8.count }

private func service(_ i: Int) -> JSONValue {
    ["package": .string("com.example.service.with.a.long.name.number\(i)"),
     "service": .string("com.example.service.with.a.long.name.number\(i).Service"), "system": false,
     "installer": "com.example.store"]
}

final class ReportSizeTests: XCTestCase {
    func testAReportThatFitsIsSentAsItIs() throws {
        let fits = report(["accessibility": ["status": "ok", "services": [service(1)], "truncated": false]])
        XCTAssertEqual(try fitReport(fits), fits)
        XCTAssertEqual(try fitReport(fits).encodedJSON, fits.encodedJSON)
    }

    func testAListTheContractLetsShortenIsHalvedAndSaysSoUntilItFits() throws {
        let big = report([
            "accessibility": ["status": "ok", "services": .array((0..<2000).map(service)), "settings_only": [],
                              "truncated": false],
            "device": ["status": "ok", "model": "m"],
        ])
        XCTAssertGreaterThan(bytes(big), reportByteLimit)
        let fitted = try fitReport(big)
        XCTAssertLessThanOrEqual(bytes(fitted), reportByteLimit)
        let accessibility = fitted["probe_results"]!["accessibility"]!
        XCTAssertEqual(accessibility["truncated"], true)
        XCTAssertLessThan(accessibility["services"]!.arrayValue!.count, 2000)
        XCTAssertEqual(fitted["probe_results"]!["device"], ["status": "ok", "model": "m"])
        XCTAssertEqual(big["probe_results"]!["accessibility"]!["services"]!.arrayValue!.count, 2000,
                       "the collector answer itself is left as it came")
    }

    func testAnythingElseTooLargeIsAnErrorNamingTheLimit() {
        let big = report(["device": ["status": "ok", "model": .string(String(repeating: "x", count: reportByteLimit + 1))]])
        XCTAssertThrowsError(try fitReport(big)) { error in
            let refusal = error as? APIError
            XCTAssertEqual(refusal?.code, "report_too_large")
            XCTAssertEqual(refusal?.details?["limit"], .int(reportByteLimit))
        }
    }
}
