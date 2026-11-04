// HTTPTransport: every call that got no answer is an APIError, the one failure an app handles.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import Necessary

/// Fails every request with `failure`, as the network would.
private final class FailingProtocol: URLProtocol {
    static var failure = URLError(.unknown)
    static var failed = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        FailingProtocol.failed += 1
        client?.urlProtocol(self, didFailWithError: FailingProtocol.failure)
    }
    override func stopLoading() {}
}

@MainActor
final class TransportTests: XCTestCase {
    private func refused(by code: URLError.Code) async -> Error? {
        FailingProtocol.failure = URLError(code)
        FailingProtocol.failed = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        let transport = HTTPTransport(baseURL: "https://backend.example", session: URLSession(configuration: configuration))
        let error = await thrown {
            try await transport.send("POST", "/v1/installations/register", encodedBody: "{}", bearerToken: nil, headers: [:])
        }
        XCTAssertEqual(FailingProtocol.failed, 1, "the request reached the failure, not the network")
        return error
    }

    func testARefusedCertificateIsAnAPIErrorNotARawTLSError() async {
        for code in [URLError.Code.serverCertificateUntrusted, .secureConnectionFailed] {
            let error = await refused(by: code)
            XCTAssertTrue(error is APIError, "\(code): \(String(describing: error))")
        }
    }

    func testSoAreASocketAndAClientFailure() async {
        for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost] {
            let error = await refused(by: code)
            XCTAssertTrue(error is APIError, "\(code): \(String(describing: error))")
        }
    }
}
