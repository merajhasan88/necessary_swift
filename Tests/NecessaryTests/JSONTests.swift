// The JSON the SDK writes and reads: written the way every Necessary SDK writes it, so that what is
// signed is what is sent; read strictly, members in their order, integers apart from other numbers.
import XCTest
@testable import Necessary

final class JSONTests: XCTestCase {
    func testTextIsEscapedOnlyWhereJSONMustBe() {
        let value: JSONValue = .string("café / € \"x\" \\ \n\t\r\u{08}\u{0C}\u{01}\u{1F} \u{7F} 😀")
        XCTAssertEqual(value.encodedJSON, "\"café / € \\\"x\\\" \\\\ \\n\\t\\r\\b\\f\\u0001\\u001f \u{7F} 😀\"")
    }

    func testNumbersAreWrittenInTheirShortestForm() {
        let cases: [(Double, String)] = [
            (5, "5.0"), (0.1, "0.1"), (-2.5, "-2.5"), (37.33233141, "37.33233141"), (1e20, "100000000000000000000.0"),
            (1e21, "1e+21"), (1.5e21, "1.5e+21"), (0.000001, "0.000001"), (1e-7, "1e-7"), (1.25e-7, "1.25e-7"),
            (123456789.125, "123456789.125"), (0, "0.0"), (65.0, "65.0"),
        ]
        for (number, text) in cases {
            XCTAssertEqual(JSONValue.double(number).encodedJSON, text, "\(number)")
        }
        XCTAssertEqual(JSONValue.int(-42).encodedJSON, "-42")
    }

    func testObjectsKeepTheirOrderAndCompareWhateverIt() throws {
        let object: JSONObject = ["b": 1, "a": [true, nil, 2.5], "c": ["z": "y"]]
        XCTAssertEqual(object.encodedJSON, #"{"b":1,"a":[true,null,2.5],"c":{"z":"y"}}"#)
        let parsed = try JSONObject(parsing: #" {"b" : 1, "a":[true, null, 2.5], "c":{"z":"y"}} "#)
        XCTAssertEqual(parsed.keys, ["b", "a", "c"])
        XCTAssertEqual(parsed.encodedJSON, object.encodedJSON)
        XCTAssertEqual(try JSONObject(parsing: #"{"a":[true,null,2.5],"c":{"z":"y"},"b":1}"#), object)
        XCTAssertEqual(JSONValue.int(1), JSONValue.double(1.0))
    }

    func testIntegersStayIntegersAndOtherNumbersDoubles() throws {
        let parsed = try JSONObject(parsing: #"{"i":7,"d":7.0,"e":1e2,"n":-0,"big":123456789012345678901234567890}"#)
        XCTAssertEqual(parsed["i"]?.intValue, 7)
        XCTAssertNil(parsed["d"]?.intValue)
        XCTAssertEqual(parsed["d"]?.numberValue, 7)
        XCTAssertEqual(parsed["e"]?.numberValue, 100)
        XCTAssertEqual(parsed["n"]?.intValue, 0)
        XCTAssertNotNil(parsed["big"]?.numberValue)
    }

    func testEscapesAndSurrogatesAreRead() throws {
        let parsed = try JSONValue(parsing: #""é😀\/\"""#)
        XCTAssertEqual(parsed.stringValue, "é😀/\"")
    }

    func testWhatIsNotJSONIsRefused() {
        for text in ["", "{", "[1,]", "{\"a\":1,}", "01", "1.", "\"\u{01}\"", "nul", "{} x", "{'a':1}"] {
            XCTAssertThrowsError(try JSONValue(parsing: text), text)
        }
    }

    func testAMemberSetAgainKeepsItsPlaceAndNilRemovesIt() {
        var object: JSONObject = ["a": 1, "b": 2]
        object["a"] = 3
        object["c"] = 4
        object["b"] = nil
        XCTAssertEqual(object.encodedJSON, #"{"a":3,"c":4}"#)
        XCTAssertEqual(object.merging(["a": 5, "d": 6]).encodedJSON, #"{"a":5,"c":4,"d":6}"#)
    }
}

final class RequestTargetTests: XCTestCase {
    func testThePathAndTheQueryAsSent() {
        let plain = RequestTarget("/v1/account/me")
        XCTAssertEqual(plain.path, "/v1/account/me")
        XCTAssertEqual(plain.query, "")
        XCTAssertFalse(plain.hasQuery)
        let query = RequestTarget("/v1/business/graph?handle=a%20b%2Bc#fragment")
        XCTAssertEqual(query.path, "/v1/business/graph")
        XCTAssertEqual(query.query, "handle=a%20b%2Bc")
        XCTAssertEqual(query.pathAndQuery, "/v1/business/graph?handle=a%20b%2Bc")
        XCTAssertTrue(RequestTarget("/v1/x?").hasQuery)
    }

    func testEscapesAreNormalizedAndWhatAURLCannotHoldIsEscaped() {
        XCTAssertEqual(RequestTarget("/v1/a%7eb%2bc").path, "/v1/a~b%2Bc")
        XCTAssertEqual(RequestTarget("/v1/a b/é").path, "/v1/a%20b/%C3%A9")
        XCTAssertEqual(RequestTarget("/v1/x?q=a b&r=%zz").query, "q=a%20b&r=%25zz")
        XCTAssertEqual(RequestTarget("/v1/x?a=1?b=/").query, "a=1?b=/")
    }

    func testDotSegmentsAreResolved() {
        XCTAssertEqual(RequestTarget("/v1/./a/../b").path, "/v1/b")
        XCTAssertEqual(RequestTarget("/v1/a/..").path, "/v1/")
    }
}
