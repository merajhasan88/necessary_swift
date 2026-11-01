import Foundation
import XCTest
@testable import Necessary

/// The files the tests share with the backends -- the measurement contract and the client-server
/// vectors -- in the nearest folder, from this file's up, that holds them; or under
/// NECESSARY_REPOSITORY.
func repositoryURL(_ path: String, file: String = #filePath) -> URL {
    if let root = ProcessInfo.processInfo.environment["NECESSARY_REPOSITORY"] {
        return URL(fileURLWithPath: root).appendingPathComponent(path)
    }
    var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
    while folder.path != "/" {
        let candidate = folder.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        folder = folder.deletingLastPathComponent()
    }
    fatalError("\(path): in no folder from \(file) up")
}

func repositoryObject(_ path: String) throws -> JSONObject {
    try JSONObject(parsing: try Data(contentsOf: repositoryURL(path)))
}

/// The contract's samples, sorted by name.
func contractSamples() throws -> [URL] {
    let folder = repositoryURL("contract/report-1/android-8-ios-5/samples")
    return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// The bytes of unpadded base64url text.
func unpadded(_ text: String) -> [UInt8] {
    [UInt8](base64UrlDecoded(text)!)
}

/// The JSON object a base64url payload carries.
func decoded(_ payload: String) throws -> JSONObject {
    try JSONObject(parsing: base64UrlDecoded(payload)!)
}

func text(_ payload: String) -> String {
    String(decoding: base64UrlDecoded(payload)!, as: UTF8.self)
}

/// What `body` threw, or nil.
@MainActor
func thrown<T>(_ body: () async throws -> T) async -> Error? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

/// The code of the NativeKeyError `body` threw.
@MainActor
func nativeCode<T>(_ body: () async throws -> T) async -> String? {
    (await thrown(body) as? NativeKeyError)?.code
}

/// The code of the APIError `body` threw.
@MainActor
func apiCode<T>(_ body: () async throws -> T) async -> String? {
    (await thrown(body) as? APIError)?.code
}

/// A one-time signal: `wait()` returns once `open()` was called -- a completer of no value.
@MainActor
final class Gate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { opened }

    func open() {
        guard !opened else { return }
        opened = true
        let waiting = self.waiting
        self.waiting = []
        for continuation in waiting { continuation.resume() }
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

/// Lets every task waiting on the main actor run: the event queue pumped.
@MainActor
func pump(_ milliseconds: UInt64 = 20) async {
    try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
}

/// A JSON object from text in a test.
func object(_ json: String) -> JSONObject {
    try! JSONObject(parsing: json)
}
