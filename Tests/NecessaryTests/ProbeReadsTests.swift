// The iOS collector's reading, ProbeReads.swift: every check of the reference's
// tools/ios/check_probe_reads/main.swift (the reads of collectors 5 to 8), run as one test. The
// fixtures' framework names are labels; the checks are the reference's, unchanged.
import Foundation
import XCTest
@testable import Necessary

private var passed = 0
private var failures: [String] = []

private func expect(_ condition: Bool, _ what: String, line: Int = #line) {
    if condition {
        passed += 1
        return
    }
    failures.append("line \(line): \(what)")
}

private func int(_ result: [String: Any], _ key: String) -> Int? { result[key] as? Int }

private func bool(_ result: [String: Any], _ key: String) -> Bool? { result[key] as? Bool }

private func image(_ path: String, _ outcome: ProbeReads.ImageOutcome, main: Bool = false) -> ProbeReads.AppImage {
    ProbeReads.AppImage(path: path, isMainExecutable: main, outcome: outcome)
}

private func compared(_ bytes: Int, differing: Int = 0) -> ProbeReads.ImageOutcome {
    .compared(textBytes: bytes, textDiffering: differing, segmentBytes: bytes + 4096, segmentDiffering: differing)
}

private func addsUp(_ r: [String: Any]) -> Bool {
    guard let expected = int(r, "app_images_expected"), let comparedImages = int(r, "app_images_compared"),
          let unreadable = int(r, "app_images_unreadable"), let skipped = int(r, "app_images_skipped"),
          let expectedBytes = int(r, "app_expected_bytes"), let comparedBytes = int(r, "app_compared_bytes"),
          let unreadableBytes = int(r, "app_unreadable_bytes"), let skippedBytes = int(r, "app_skipped_bytes"),
          let complete = bool(r, "app_complete") else { return false }
    let named = (r["app_images_not_compared"] as? [String: String])?.count ?? 0
    return expected == comparedImages + unreadable + skipped
        && expectedBytes == comparedBytes + unreadableBytes + skippedBytes
        && complete == (expected > 0 && comparedImages == expected)
        && named == min(ProbeReads.maxNamedImages, unreadable + skipped)
}

private func machO(uuid: [UInt8]?, magic: UInt32 = 0xfeed_facf) -> [UInt8] {
    func le(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    let segment = le(0x19) + le(72) + [UInt8](repeating: 0, count: 64)
    let uuidCommand = uuid.map { le(0x1b) + le(24) + $0 } ?? []
    let commands = segment + uuidCommand
    let count = uuid == nil ? 1 : 2
    return le(Int(magic)) + le(0x0100000c) + le(0) + le(2) + le(count) + le(commands.count) + le(0) + le(0)
        + commands
}

final class ProbeReadsTests: XCTestCase {
    func testTheCollectorsReads() {
        passed = 0
        failures = []






        /// The figures add up, whatever the outcomes: images and bytes alike.

        // MARK: - R2: app-code coverage

        let main = image("Runner", compared(180_224), main: true)
        let engine = image("Frameworks/Engine.framework/Engine", compared(4_194_304))
        let app = image("Frameworks/App.framework/App", compared(5_914_624))

        do {  // Every image compared, the main executable among them: complete.
            let r = ProbeReads.appCoverage([main, engine, app], systemImagesUnreadable: 435)
            expect(addsUp(r), "complete coverage adds up")
            expect(bool(r, "app_complete") == true && bool(r, "checked") == true, "every image compared: complete")
            expect(bool(r, "main_executable_compared") == true, "the main executable is among them")
            expect(int(r, "app_compared_bytes") == 180_224 + 4_194_304 + 5_914_624, "the compared bytes")
            expect(r["app_images_not_compared"] == nil, "nothing to name")
            expect(int(r, "system_images_unreadable") == 435, "the shared-cache images counted apart")
        }

        do {  // Two images, one readable and one unreadable (the review's first case).
            let unread = image("Frameworks/App.framework/App", .unreadable(textBytes: 5_914_624, why: "unreadable: the file could not be opened"))
            let r = ProbeReads.appCoverage([main, unread], systemImagesUnreadable: 435)
            expect(addsUp(r), "one unreadable image adds up")
            expect(bool(r, "app_complete") == false && bool(r, "checked") == true, "partial, never complete")
            expect(int(r, "app_images_unreadable") == 1 && int(r, "app_unreadable_bytes") == 5_914_624,
                   "the unreadable image and its bytes are counted")
            expect((r["app_images_not_compared"] as? [String: String])?["Frameworks/App.framework/App"]
                   == "unreadable: the file could not be opened", "and named with why")
            expect(int(r, "system_images_unreadable") == 435, "never counted with the system images")
        }

        do {  // The review's fixture: one small image compared, the main executable not.
            let r = ProbeReads.appCoverage(
                [image("Runner", .unreadable(textBytes: 180_224, why: "unreadable: 0 of 180224 bytes read"), main: true),
                 image("Frameworks/small.framework/small", compared(4096))],
                systemImagesUnreadable: 101)
            expect(addsUp(r), "the review's case adds up")
            expect(bool(r, "app_complete") == false && bool(r, "main_executable_compared") == false,
                   "one small framework never makes the comparison complete")
        }

        do {  // A missing or invalid text span: skipped, with no bytes when the size is unknown.
            let missing = ProbeReads.textSpan(segmentFileOffset: 0, segmentFileSize: 8192, segmentVMAddress: 0, section: nil)
            expect(missing == .failure(ProbeReads.CoverageProblem(reason: "no __text section in __TEXT", textSize: 0)),
                   "no __text section")
            let empty = ProbeReads.textSpan(segmentFileOffset: 0, segmentFileSize: 8192, segmentVMAddress: 0,
                                            section: (offset: 4096, size: 0))
            expect(empty == .failure(ProbeReads.CoverageProblem(reason: "an empty __text section", textSize: 0)),
                   "an empty __text")
            for (offset, size) in [(UInt64(0), UInt64(9000)), (UInt64(9000), UInt64(4096)), (UInt64(UInt64.max), UInt64(1)),
                                   (UInt64(4096), UInt64.max)] {
                let outside = ProbeReads.textSpan(segmentFileOffset: 4096, segmentFileSize: 8192, segmentVMAddress: 0,
                                                  section: (offset: offset, size: size))
                expect(outside == .failure(ProbeReads.CoverageProblem(reason: "__text lies outside its __TEXT segment",
                                                                      textSize: 0)),
                       "__text at \(offset)+\(size) outside its segment, no trap on huge values")
            }
            let r = ProbeReads.appCoverage([main, engine, image("Frameworks/App.framework/App",
                                                                 .skipped(textBytes: 0, why: "no __text section in __TEXT"))],
                                           systemImagesUnreadable: 435)
            expect(addsUp(r), "a skipped image of unknown size adds up")
            expect(bool(r, "app_complete") == false, "the images decide: bytes compared equal bytes expected, still partial")
            expect(int(r, "app_compared_bytes") == int(r, "app_expected_bytes"), "(the bytes alone would say complete)")
        }

        do {  // A valid segment beyond the budget: skipped, with its size.
            let big = ProbeReads.textSpan(segmentFileOffset: 0, segmentFileSize: 70_000_000, segmentVMAddress: 0,
                                          section: (offset: 16384, size: 60_000_000))
            expect(big == .failure(ProbeReads.CoverageProblem(reason: "__TEXT of 70000000 bytes is over the 64 MiB budget",
                                                              textSize: 60_000_000)),
                   "over the budget: skipped with its size")
            let huge = ProbeReads.textSpan(segmentFileOffset: 0, segmentFileSize: UInt64.max, segmentVMAddress: 0,
                                           section: (offset: 0, size: UInt64.max))
            if case .failure(let problem) = huge {
                expect(problem.textSize == 0, "an absurd size is not reported as bytes")
            } else {
                expect(false, "an absurd segment is never compared")
            }
            let fits = ProbeReads.textSpan(segmentFileOffset: 0, segmentFileSize: 8_716_288, segmentVMAddress: 0x1000,
                                           section: (offset: 16384, size: 4_194_304))
            expect(fits == .success(ProbeReads.TextSpan(segmentFileOffset: 0, segmentSize: 8_716_288, segmentVMAddress: 0x1000,
                                                        textOffsetInSegment: 16384, textSize: 4_194_304)),
                   "a segment within the budget is compared")
        }

        do {  // A partial file read is unreadable, never a comparison of part.
            expect(ProbeReads.readProblem(got: 4096, wanted: 5_914_624) == "unreadable: 4096 of 5914624 bytes read",
                   "a short read")
            expect(ProbeReads.readProblem(got: 0, wanted: 4096) == "unreadable: 0 of 4096 bytes read", "an empty read")
            expect(ProbeReads.readProblem(got: 4096, wanted: 4096) == nil, "a whole read")
        }

        do {  // Nothing compared: not checked, nothing measured.
            let r = ProbeReads.appCoverage([image("Runner", .unreadable(textBytes: 180_224, why: "unreadable: x"), main: true)],
                                           systemImagesUnreadable: 435)
            expect(bool(r, "checked") == false && bool(r, "app_complete") == false, "not one image compared")
            let none = ProbeReads.appCoverage([], systemImagesUnreadable: 435)
            expect(bool(none, "checked") == false && bool(none, "app_complete") == false && addsUp(none), "no image at all")
        }

        do {  // A differing byte is counted, and its image named.
            let r = ProbeReads.appCoverage([main, image("Frameworks/Engine.framework/Engine", compared(4_194_304, differing: 16))],
                                           systemImagesUnreadable: 435)
            expect(int(r, "app_diff_bytes") == 16 && int(r, "app_libs_diff") == 1 && r["diffed_libs"] as? String == "Engine",
                   "16 differing bytes in Engine")
        }

        do {  // Names: the path in the bundle, at most 128 characters with its end kept; at most 64 named.
            expect(ProbeReads.bundleLabel(imagePath: "/var/x/Runner.app/Frameworks/App.framework/App", bundlePath: "/var/x/Runner.app")
                   == "Frameworks/App.framework/App", "a path in the bundle")
            expect(ProbeReads.bundleLabel(imagePath: "/var/x/Runner.app", bundlePath: "/var/x/Runner.app") == "(bundle)",
                   "the bundle itself")
            let long = "/b/" + String(repeating: "d/", count: 100) + "Lib"
            let label = ProbeReads.bundleLabel(imagePath: long, bundlePath: "/b")
            expect(label.count == 128 && label.hasSuffix("/Lib"), "a long path keeps its end")
            let many = (0..<80).map { image("Frameworks/F\($0).framework/F\($0)", .skipped(textBytes: 10, why: "no live address for __TEXT")) }
            let r = ProbeReads.appCoverage(many, systemImagesUnreadable: 0)
            expect(addsUp(r) && (r["app_images_not_compared"] as? [String: String])?.count == 64, "at most 64 named, all counted")
        }

        do {  // The arithmetic holds for every mix of outcomes.
            let outcomes: [ProbeReads.ImageOutcome] = [compared(100), .unreadable(textBytes: 50, why: "unreadable: x"),
                                                        .skipped(textBytes: 0, why: "no __TEXT segment"),
                                                        .skipped(textBytes: 70, why: "over the budget")]
            for mask in 0..<256 {
                var images: [ProbeReads.AppImage] = []
                for slot in 0..<4 where mask & (1 << slot) != 0 {
                    images.append(image("I\(slot)", outcomes[slot], main: slot == 0))
                }
                for slot in 0..<4 where mask & (1 << (slot + 4)) != 0 {
                    images.append(image("J\(slot)", outcomes[slot]))
                }
                expect(addsUp(ProbeReads.appCoverage(images, systemImagesUnreadable: 1)), "mix \(mask) adds up")
            }
        }

        // MARK: - R3: one location read per collection

        let now = Date(timeIntervalSince1970: 1_792_857_600)
        let real = ProbeReads.Fix(latitude: 24.86, longitude: 67.0, horizontalAccuracy: 35, timestamp: now.addingTimeInterval(-10),
                                  simulatedBySoftware: false, producedByAccessory: false)
        let mocked = ProbeReads.Fix(latitude: 51.5, longitude: -0.12, horizontalAccuracy: 5, timestamp: now.addingTimeInterval(-9),
                                    simulatedBySoftware: true, producedByAccessory: false)

        do {  // A source alternating a real and a mocked fix on every read.
            var reads = 0
            let source: () -> ProbeReads.LocationRead = {
                reads += 1
                return ProbeReads.read(permission: "precise", fix: reads % 2 == 1 ? real : mocked, now: now)
            }
            let scan = ProbeReads.LocationCapture(source)
            let location = ProbeReads.location(scan.value)
            let mock = ProbeReads.mockLocation(scan.value)
            expect(reads == 1, "one read for both measurements")
            expect(location["latitude"] as? Double == 24.86 && mock["mock"] as? Bool == false, "both describe the real fix")
            expect(int(location, "fix_time") == 1_792_857_590 && int(location, "fix_time") == int(mock, "fix_time"),
                   "one fix time in both")
            expect(int(location, "age_seconds") == 10 && int(mock, "age_seconds") == 10, "one age in both")
            expect(mock["latitude"] == nil && mock["longitude"] == nil && mock["accuracy_m"] == nil, "no coordinates in the mock answer")
            let next = ProbeReads.LocationCapture(source)
            expect(ProbeReads.mockLocation(next.value)["mock"] as? Bool == true
                   && ProbeReads.location(next.value)["latitude"] as? Double == 51.5 && reads == 2,
                   "the next scan reads again, in either order, and gets one fix again")
        }

        do {  // No permission: no fix is read, whatever the phone holds.
            let read = ProbeReads.read(permission: "none", fix: real, now: now)
            expect(read.fix == nil, "no fix without the permission")
            for answer in [ProbeReads.location(read), ProbeReads.mockLocation(read)] {
                expect(answer.count == 2 && answer["permission"] as? String == "none", "only the permission")
            }
        }

        do {  // Permission revoked during the collection: both answer from the one read already made.
            var permission = "precise"
            let scan = ProbeReads.LocationCapture { ProbeReads.read(permission: permission, fix: real, now: now) }
            let location = ProbeReads.location(scan.value)
            permission = "none"
            let mock = ProbeReads.mockLocation(scan.value)
            expect(location["permission"] as? String == "precise" && mock["permission"] as? String == "precise"
                   && int(location, "fix_time") == int(mock, "fix_time"), "one permission, one fix")
        }

        do {  // No fix held: the permission alone.
            let read = ProbeReads.read(permission: "approximate", fix: nil, now: now)
            expect(ProbeReads.location(read).count == 2 && ProbeReads.mockLocation(read).count == 2, "no fix")
        }

        do {  // A stale fix: one age, computed once.
            let old = ProbeReads.Fix(latitude: 1, longitude: 2, horizontalAccuracy: -1, timestamp: now.addingTimeInterval(-3600),
                                     simulatedBySoftware: nil, producedByAccessory: nil)
            let read = ProbeReads.read(permission: "precise", fix: old, now: now)
            let location = ProbeReads.location(read)
            let mock = ProbeReads.mockLocation(read)
            expect(int(location, "age_seconds") == 3600 && int(mock, "age_seconds") == 3600, "the same age in both")
            expect(location["accuracy_m"] == nil, "an unknown accuracy is not sent")
            expect(mock["mock"] == nil && mock["accessory"] == nil && int(mock, "fix_time") == 1_792_854_000,
                   "a fix that cannot say: no mock flag, still its time")
        }

        do {  // A fix from the future (a clock set back) is age 0, never negative.
            let ahead = ProbeReads.Fix(latitude: 1, longitude: 2, horizontalAccuracy: 3, timestamp: now.addingTimeInterval(30),
                                       simulatedBySoftware: false, producedByAccessory: false)
            expect(ProbeReads.read(permission: "precise", fix: ahead, now: now).ageSeconds == 0, "never a negative age")
        }

        // Screen capture (collector 6): no screen of the app's to ask is unknown, never "no".
        do {
            let recorded = ProbeReads.screenCapture(captured: true, otherScreens: 1)
            expect(bool(recorded, "recording") == true && recorded["recording_status"] == nil
                   && int(recorded, "external_displays") == 1, "a captured screen: recording true, one other screen")
            let clean = ProbeReads.screenCapture(captured: false, otherScreens: 0)
            expect(bool(clean, "recording") == false && clean["recording_status"] == nil
                   && int(clean, "external_displays") == 0, "a screen not captured: recording false")
            let unasked = ProbeReads.screenCapture(captured: nil, otherScreens: 0)
            expect(unasked["recording"] == nil && (unasked["recording_status"] as? String) == "unavailable"
                   && (unasked["status"] as? String) == "ok" && int(unasked, "external_displays") == 0,
                   "no window scene in the foreground: recording left out, unavailable, the screens still counted")
            expect(int(ProbeReads.screenCapture(captured: false, otherScreens: -1), "external_displays") == 0,
                   "never a negative count of screens")
        }

        // App Store encryption (collector 7): an image whose __text the App Store
        // encrypted on disk is skipped with its bytes, never compared.
        do {
            // A main executable: __TEXT at file offset 0, its __text from 0x4000, 1 MiB.
            let span = ProbeReads.TextSpan(segmentFileOffset: 0, segmentSize: 0x200000, segmentVMAddress: 0x1_0000_0000,
                                           textOffsetInSegment: 0x4000, textSize: 0x100000)
            let encrypted = ProbeReads.encryptionProblem(cryptOffset: 0x4000, cryptSize: 0x1FC000, cryptID: 1, span: span)
            expect(encrypted != nil && encrypted?.textSize == 0x100000
                   && encrypted?.reason.hasPrefix("encrypted on disk") == true,
                   "encrypted over __text: skipped, with its __text bytes")
            expect(ProbeReads.encryptionProblem(cryptOffset: 0x4000, cryptSize: 0x1FC000, cryptID: 0, span: span) == nil,
                   "cryptid 0 (stored in the clear, as a dumped or development build is): compared")
            expect(ProbeReads.encryptionProblem(cryptOffset: 0x4000, cryptSize: 0, cryptID: 1, span: span) == nil,
                   "an empty encrypted range: compared")
            expect(ProbeReads.encryptionProblem(cryptOffset: 0x104000, cryptSize: 0x1000, cryptID: 1, span: span) == nil,
                   "an encrypted range after __text ends: compared")
            expect(ProbeReads.encryptionProblem(cryptOffset: 0, cryptSize: 0x4000, cryptID: 1, span: span) == nil,
                   "an encrypted range before __text begins: compared")
            expect(ProbeReads.encryptionProblem(cryptOffset: 0x103FFF, cryptSize: 1, cryptID: 1, span: span) != nil,
                   "one encrypted byte inside __text: skipped")
            let images = [
                ProbeReads.AppImage(path: "Runner", isMainExecutable: true,
                                    outcome: .skipped(textBytes: 0x100000, why: encrypted!.reason)),
                ProbeReads.AppImage(path: "Frameworks/App.framework/App", isMainExecutable: false,
                                    outcome: .compared(textBytes: 4096, textDiffering: 0, segmentBytes: 8192, segmentDiffering: 0)),
            ]
            let r = ProbeReads.appCoverage(images, systemImagesUnreadable: 0)
            expect(bool(r, "app_complete") == false && bool(r, "main_executable_compared") == false
                   && int(r, "app_skipped_bytes") == 0x100000 && int(r, "app_diff_bytes") == 0,
                   "an encrypted main executable: incomplete, its bytes skipped, no difference invented")
        }

        // MARK: - Collector 8: the build that is running, the images dyld cannot name, capped lists

        /// A 64-bit Mach-O header with a __TEXT segment command and, optionally, an LC_UUID.

        let running: [UInt8] = Array(0..<16)
        let updated: [UInt8] = Array(100..<116)

        do {  // LC_UUID read from a file's header and load commands.
            expect(ProbeReads.machOUUID(machO(uuid: running)) == running, "the LC_UUID after a segment command is found")
            expect(ProbeReads.machOUUID(machO(uuid: nil)) == nil, "no LC_UUID: nil")
            expect(ProbeReads.machOUUID(machO(uuid: running, magic: 0xcafe_babe)) == nil, "not a 64-bit Mach-O: nil")
            expect(ProbeReads.machOUUID(Array(machO(uuid: running).prefix(100))) == nil,
                   "load commands cut short: nil, never bytes past the end")
            expect(ProbeReads.machOUUID([]) == nil, "nothing read: nil")
        }

        do {  // The file must be the build that is running.
            expect(ProbeReads.buildProblem(loaded: running, onDisk: running, textSize: 4096) == nil,
                   "the same build on disk: compared")
            let other = ProbeReads.buildProblem(loaded: running, onDisk: updated, textSize: 4096)
            expect(other?.textSize == 4096 && other?.reason.contains("LC_UUID differs") == true,
                   "another build on disk (an app updated while it ran): skipped with its __text bytes")
            expect(ProbeReads.buildProblem(loaded: running, onDisk: nil, textSize: 4096) != nil,
                   "a file with no LC_UUID is not the image loaded: skipped")
            expect(ProbeReads.buildProblem(loaded: nil, onDisk: updated, textSize: 4096) == nil,
                   "a loaded image with no LC_UUID: nothing to tell by, compared")
            let images = [
                ProbeReads.AppImage(path: "Runner", isMainExecutable: true, outcome: .skipped(textBytes: 191_160, why: other!.reason)),
                engine, app,
            ]
            let r = ProbeReads.appCoverage(images, systemImagesUnreadable: 435)
            expect(addsUp(r) && bool(r, "app_complete") == false && int(r, "app_diff_bytes") == 0
                   && int(r, "app_skipped_bytes") == 191_160 && bool(r, "main_executable_compared") == false,
                   "the TrollStore case of 2026-10-31: the main executable skipped, no difference invented, incomplete")
        }

        do {  // An image dyld counts but cannot name: an app image not read, never dropped.
            let r = ProbeReads.appCoverage([main, engine, app, ProbeReads.unlistedImage(index: 7)],
                                           systemImagesUnreadable: 435)
            expect(addsUp(r), "an unlisted image adds up")
            expect(bool(r, "app_complete") == false && int(r, "app_images_unreadable") == 1
                   && int(r, "app_unreadable_bytes") == 0,
                   "an unlisted image: incomplete, and no byte count invented for it")
            expect((r["app_images_not_compared"] as? [String: String])?["image 7"] == "dyld gave no name or header for it",
                   "the unlisted image is named with why")
            expect(ProbeReads.unnamedImages(0, of: 412).isEmpty, "every name read: nothing unread")
            expect(ProbeReads.unnamedImages(2, of: 412) == ["image_names": "2 of 412 could not be read"],
                   "names dyld did not give are unread")
        }

        do {  // A universal file: the image is its arm64 slice, never the file's start.
            func be(_ value: Int) -> [UInt8] { (0..<4).reversed().map { UInt8((value >> (8 * $0)) & 0xff) } }
            let thin = machO(uuid: running)
            expect(ProbeReads.arm64Slice(thin) == 0, "a 64-bit Mach-O file: the image is the file")
            // One arm64 slice at 16384, as a framework is built that nothing thinned (cafebabe, 1 architecture).
            let fat = be(0xcafe_babe) + be(1) + be(0x0100_000c) + be(0) + be(16384) + be(5_830_480) + be(14)
            expect(ProbeReads.arm64Slice(fat) == 16384, "a universal file with one arm64 slice: its offset")
            let twoArchs = be(0xcafe_babe) + be(2) + be(0x0100_0007) + be(3) + be(4096) + be(100) + be(12)
                + be(0x0100_000c) + be(0) + be(65536) + be(100) + be(14)
            expect(ProbeReads.arm64Slice(twoArchs) == 65536, "x86_64 then arm64: the arm64 slice")
            let noArm = be(0xcafe_babe) + be(1) + be(0x0100_0007) + be(3) + be(4096) + be(100) + be(12)
            expect(ProbeReads.arm64Slice(noArm) == nil, "a universal file without arm64: not comparable")
            expect(ProbeReads.arm64Slice(Array(fat.prefix(12))) == nil, "a universal header cut short: nil")
            expect(ProbeReads.arm64Slice([0, 0, 0, 0, 0, 0, 0, 0]) == nil, "neither: nil")
        }

        do {  // The app's own names are no tool's; what it carries beside them is read.
            let tokens = ["tool", "gadget", "flex"]
            let bundle = "/private/var/containers/Bundle/Application/A1B2/Toolbox.app"
            func named(_ path: String) -> [String] {
                ProbeReads.imageTokens(path: path, bundlePath: bundle, mainExecutable: "Toolbox", tokens: tokens)
            }
            expect(named(bundle + "/Toolbox").isEmpty, "the main executable names no tool")
            expect(named(bundle + "/Frameworks/Engine.framework/Engine").isEmpty, "the bundle's path names no tool")
            expect(named(bundle + "/Frameworks/ToolGadget.dylib") == ["tool", "gadget"],
                   "a library the app was rebuilt with is found by its own name")
            expect(named("/usr/lib/libFLEX.dylib") == ["flex"], "an image outside the bundle is read whole")
            expect(ProbeReads.imageTokens(path: bundle + "/Toolbox", bundlePath: bundle, mainExecutable: nil, tokens: tokens)
                   == ["tool"], "with no main executable to tell by, the name is read")
        }

        XCTAssertEqual(failures, [], "the broken expectations")
        XCTAssertEqual(passed, 343, "every check of tools/ios/check_probe_reads ran")
    }
}
