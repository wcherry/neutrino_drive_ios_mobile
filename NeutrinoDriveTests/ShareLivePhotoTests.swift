import XCTest
@testable import NeutrinoDrive

// MARK: - Fakes

/// A shared item that may be a Live Photo. Its bundle is a temp directory holding the still and
/// the clip under the names given, the way the share extension copies one out.
private final class FakeLiveAttachment: ShareAttachment {
    let suggestedName: String
    let still: Data
    let clip: Data?
    var bundleNames = (still: "photo.heic", clip: "video.mov")
    private(set) var loadFileCalls = 0
    private(set) var loadLivePhotoCalls = 0
    private(set) var bundleDirectory: URL?

    init(name: String = "IMG_1234", still: Data = Data("still-bytes".utf8),
         clip: Data? = Data("clip-bytes".utf8)) {
        self.suggestedName = name
        self.still = still
        self.clip = clip
    }

    func loadFile() async throws -> URL {
        loadFileCalls += 1
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent(suggestedName)
        try still.write(to: url)
        return url
    }

    func loadLivePhoto() async -> LivePhotoFiles? {
        loadLivePhotoCalls += 1
        guard let clip, let dir = try? makeDirectory() else { return nil }
        let bundle = dir.appendingPathComponent("IMG_1234.pvt", isDirectory: true)
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? still.write(to: bundle.appendingPathComponent(bundleNames.still))
        try? clip.write(to: bundle.appendingPathComponent(bundleNames.clip))
        bundleDirectory = dir
        return LivePhotoFiles.find(in: bundle, deleting: dir)
    }

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private struct Boom: LocalizedError {
    var errorDescription: String? { "server said no" }
}

/// One upload the coordinator made.
private struct Sent: Equatable {
    let name: String
    let mimeType: String
    let data: Data
}

// MARK: - Coordinator

final class ShareLivePhotoTests: XCTestCase {

    private func makeSUT(maxItemBytes: Int64 = ShareLimits.maxItemBytes, keepsMotion: Bool = true,
                         failing: Set<String> = []) -> (ShareUploadCoordinator, () -> [Sent]) {
        let sut = ShareUploadCoordinator(maxItemBytes: maxItemBytes)
        sut.hasStoredKeysProvider = { true }
        sut.hasAccessTokenProvider = { true }
        sut.keepsLivePhotoMotion = { keepsMotion }
        var sent: [Sent] = []
        sut.uploadHandler = { data, name, mime, _ in
            if failing.contains(name) { throw Boom() }
            sent.append(Sent(name: name, mimeType: mime, data: data))
            return UploadResult(id: "id-\(name)", name: name, folderId: nil,
                                sizeBytes: Int64(data.count), mimeType: mime, updatedAt: Date())
        }
        return (sut, { sent })
    }

    func testALivePhotoUploadsItsStillAndClipUnderOneStem() async {
        let (sut, sent) = makeSUT()
        let item = FakeLiveAttachment()

        let results = await sut.run(attachments: [item])

        XCTAssertEqual(sent(), [
            Sent(name: "IMG_1234.heic", mimeType: "image/heic", data: Data("still-bytes".utf8)),
            Sent(name: "IMG_1234.mov", mimeType: "video/quicktime", data: Data("clip-bytes".utf8)),
        ], "both halves, byte for byte, the clip named after the still")
        XCTAssertEqual(results, [ShareItemResult(name: "IMG_1234", outcome: .uploaded(id: "id-IMG_1234.heic"))],
                       "one Live Photo is one item")
        XCTAssertEqual(item.loadFileCalls, 0)
    }

    func testTheBundleIsDeletedAfterwards() async throws {
        let (sut, _) = makeSUT()
        let item = FakeLiveAttachment()
        _ = await sut.run(attachments: [item])
        let dir = try XCTUnwrap(item.bundleDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testWithMotionOffOnlyTheStillIsShared() async {
        let (sut, sent) = makeSUT(keepsMotion: false)
        let item = FakeLiveAttachment()

        _ = await sut.run(attachments: [item])

        XCTAssertEqual(item.loadLivePhotoCalls, 0, "the bundle isn't even read")
        XCTAssertEqual(item.loadFileCalls, 1)
        XCTAssertEqual(sent().map(\.name), ["IMG_1234"], "exactly as before #44")
    }

    func testAnItemThatIsNotALivePhotoGoesTheOldWay() async {
        let (sut, sent) = makeSUT()
        let item = FakeLiveAttachment(clip: nil)

        let results = await sut.run(attachments: [item])

        XCTAssertEqual(item.loadFileCalls, 1)
        XCTAssertEqual(sent().map(\.name), ["IMG_1234"])
        XCTAssertEqual(results.first?.outcome, .uploaded(id: "id-IMG_1234"))
    }

    func testAClipThatFailsLeavesThePhotoAndSaysSo() async {
        let (sut, sent) = makeSUT(failing: ["IMG_1234.mov"])

        let results = await sut.run(attachments: [FakeLiveAttachment()])

        XCTAssertEqual(sent().map(\.name), ["IMG_1234.heic"], "the still is sent once, not retried")
        guard case .partlyUploaded(let id, let message) = results.first?.outcome else {
            return XCTFail("expected partlyUploaded, got \(String(describing: results.first?.outcome))")
        }
        XCTAssertEqual(id, "id-IMG_1234.heic")
        XCTAssertTrue(message.contains("server said no"))
        XCTAssertFalse(results[0].outcome.isSuccess, "a Live Photo that arrived as a still is not a success")
    }

    func testAStillThatFailsIsAFailureAndTheClipIsNotTried() async {
        let (sut, sent) = makeSUT(failing: ["IMG_1234.heic"])

        let results = await sut.run(attachments: [FakeLiveAttachment()])

        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(results.first?.outcome, .failed(message: "server said no"))
    }

    func testThePhotoIsSharedWithoutMotionWhenThePairIsTooLarge() async {
        // 11 + 10 bytes: the still fits under 15, the pair doesn't.
        let (sut, sent) = makeSUT(maxItemBytes: 15)

        let results = await sut.run(attachments: [FakeLiveAttachment()])

        XCTAssertEqual(sent().map(\.name), ["IMG_1234.heic"])
        XCTAssertEqual(results.first?.outcome,
                       .partlyUploaded(id: "id-IMG_1234.heic", message: ShareLimits.motionTooLargeMessage))
    }

    func testAStillTooLargeOnItsOwnIsRefusedOutright() async {
        let (sut, sent) = makeSUT(maxItemBytes: 5)

        let results = await sut.run(attachments: [FakeLiveAttachment()])

        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(results.first?.outcome, .failed(message: ShareLimits.oversizeMessage))
    }

    func testAMixedShareCountsItemsNotFiles() async {
        let (sut, sent) = makeSUT()
        let live = FakeLiveAttachment(name: "IMG_0001")
        let plain = FakeLiveAttachment(name: "IMG_0002", clip: nil)

        let results = await sut.run(attachments: [live, plain])

        XCTAssertEqual(sent().map(\.name), ["IMG_0001.heic", "IMG_0001.mov", "IMG_0002"])
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy(\.outcome.isSuccess))
    }

    // MARK: Naming and bundle layout

    func testTheStillTakesTheSuggestedNameAndItsOwnExtension() {
        let heic = URL(fileURLWithPath: "/tmp/b/photo.heic")
        XCTAssertEqual(ShareUploadCoordinator.stillFileName(suggested: "IMG_1234", file: heic), "IMG_1234.heic")
        XCTAssertEqual(ShareUploadCoordinator.stillFileName(suggested: "IMG_1234.HEIC", file: heic), "IMG_1234.HEIC")
        XCTAssertEqual(ShareUploadCoordinator.stillFileName(suggested: "  ", file: heic), "photo.heic")
        XCTAssertEqual(ShareUploadCoordinator.stillFileName(suggested: "Trip v1.2",
                                                            file: URL(fileURLWithPath: "/tmp/b/a.jpg")),
                       "Trip v1.2.jpg")
    }

    func testFindsTheStillAndClipAnywhereInTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("Info.plist"))
        try Data("s".utf8).write(to: nested.appendingPathComponent("IMG_9.JPG"))
        try Data("c".utf8).write(to: nested.appendingPathComponent("IMG_9.MOV"))

        let files = try XCTUnwrap(LivePhotoFiles.find(in: root, deleting: root))
        XCTAssertEqual(files.still.lastPathComponent, "IMG_9.JPG")
        XCTAssertEqual(files.clip.lastPathComponent, "IMG_9.MOV")
    }

    func testABundleWithoutAClipIsNotALivePhoto() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("s".utf8).write(to: root.appendingPathComponent("IMG_9.HEIC"))
        XCTAssertNil(LivePhotoFiles.find(in: root, deleting: root))
    }

    func testMotionIsKeptUnlessTurnedOff() throws {
        let suite = "ShareLivePhotoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertTrue(LivePhotoMotionRules.keepsMotion(defaults))
        defaults.set(false, forKey: PhotoSyncKeys.keepLivePhotoMotion)
        XCTAssertFalse(LivePhotoMotionRules.keepsMotion(defaults), "the share extension reads Photo Sync's setting")
    }
}
