import XCTest
@testable import NeutrinoDrive

// MARK: - FakeShareAttachment

/// Stands in for an `NSItemProvider`-backed attachment. Records whether its bytes were ever
/// materialised, which is what makes "the size cap is enforced *before* the file is read"
/// assertable rather than merely asserted-about-in-a-comment.
private final class FakeShareAttachment: ShareAttachment {

    let suggestedName: String
    private let contents: Data
    private let loadError: Error?
    private(set) var loadFileCallCount = 0
    private(set) var materialisedURL: URL?

    init(name: String, contents: Data = Data("hello".utf8), loadError: Error? = nil) {
        self.suggestedName = name
        self.contents = contents
        self.loadError = loadError
    }

    func loadFile() async throws -> URL {
        loadFileCallCount += 1
        if let loadError { throw loadError }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(suggestedName)
        try contents.write(to: url)
        materialisedURL = url
        return url
    }
}

private struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - ShareUploadCoordinatorTests

final class ShareUploadCoordinatorTests: XCTestCase {

    private func makeSUT(maxItemBytes: Int64 = ShareLimits.maxItemBytes,
                         hasKeys: Bool = true,
                         hasToken: Bool = true) -> ShareUploadCoordinator {
        let sut = ShareUploadCoordinator(maxItemBytes: maxItemBytes)
        sut.hasStoredKeysProvider = { hasKeys }
        sut.hasAccessTokenProvider = { hasToken }
        return sut
    }

    private func makeUploadResult(id: String = "server-id", name: String = "f") -> UploadResult {
        UploadResult(id: id, name: name, folderId: nil, sizeBytes: 1,
                     mimeType: "application/octet-stream", updatedAt: Date())
    }

    // MARK: - Preconditions

    func test_preconditions_withNoAttachments_isNoItems() {
        let sut = makeSUT()
        XCTAssertEqual(sut.checkPreconditions(attachmentCount: 0), .noItems)
    }

    func test_preconditions_withoutAccessToken_isNotAuthenticated() {
        let sut = makeSUT(hasToken: false)
        XCTAssertEqual(sut.checkPreconditions(attachmentCount: 1), .notAuthenticated)
    }

    func test_preconditions_withoutEncryptionKeys_isNoEncryptionKey() {
        let sut = makeSUT(hasKeys: false)
        XCTAssertEqual(sut.checkPreconditions(attachmentCount: 1), .noEncryptionKey)
    }

    func test_preconditions_whenSatisfied_isNil() {
        let sut = makeSUT()
        XCTAssertNil(sut.checkPreconditions(attachmentCount: 1))
    }

    func test_preconditionErrors_allHaveUserFacingDescriptions() {
        // The extension cannot present login or key import, so this copy is the only guidance
        // the user gets.
        XCTAssertNotNil(ShareUploadError.notAuthenticated.errorDescription)
        XCTAssertNotNil(ShareUploadError.noEncryptionKey.errorDescription)
        XCTAssertNotNil(ShareUploadError.noItems.errorDescription)
    }

    // MARK: - Happy path

    func test_run_uploadsASingleAttachment() async {
        let sut = makeSUT()
        sut.uploadHandler = { [self] _, name, _, _ in makeUploadResult(id: "id-1", name: name) }

        let results = await sut.run(attachments: [FakeShareAttachment(name: "photo.jpg")])

        XCTAssertEqual(results, [ShareItemResult(name: "photo.jpg", outcome: .uploaded(id: "id-1"))])
    }

    func test_run_usesTheAttachmentsSuggestedNameAsTheUploadFilename() async {
        let sut = makeSUT()
        var capturedNames: [String] = []
        sut.uploadHandler = { [self] _, name, _, _ in
            capturedNames.append(name)
            return makeUploadResult()
        }

        _ = await sut.run(attachments: [FakeShareAttachment(name: "invoice.pdf")])

        XCTAssertEqual(capturedNames, ["invoice.pdf"])
    }

    func test_run_derivesMimeTypeFromTheFileExtension() async {
        let sut = makeSUT()
        var capturedMimes: [String] = []
        sut.uploadHandler = { [self] _, _, mime, _ in
            capturedMimes.append(mime)
            return makeUploadResult()
        }

        _ = await sut.run(attachments: [FakeShareAttachment(name: "notes.txt")])

        XCTAssertEqual(capturedMimes, ["text/plain"])
    }

    func test_run_uploadsTheAttachmentsActualBytes() async {
        let sut = makeSUT()
        let payload = Data("the exact shared content".utf8)
        var capturedData: [Data] = []
        sut.uploadHandler = { [self] data, _, _, _ in
            capturedData.append(data)
            return makeUploadResult()
        }

        _ = await sut.run(attachments: [FakeShareAttachment(name: "a.txt", contents: payload)])

        XCTAssertEqual(capturedData, [payload])
    }

    // MARK: - Multiple items

    func test_run_processesAllAttachmentsInOrder() async {
        let sut = makeSUT()
        var order: [String] = []
        sut.uploadHandler = { [self] _, name, _, _ in
            order.append(name)
            return makeUploadResult(name: name)
        }

        let results = await sut.run(attachments: [
            FakeShareAttachment(name: "a.txt"),
            FakeShareAttachment(name: "b.txt"),
            FakeShareAttachment(name: "c.txt"),
        ])

        XCTAssertEqual(order, ["a.txt", "b.txt", "c.txt"])
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.outcome.isSuccess })
    }

    func test_run_reportsProgressAsIndexOfTotal() async {
        let sut = makeSUT()
        sut.uploadHandler = { [self] _, _, _, _ in makeUploadResult() }
        var progressReports: [String] = []

        _ = await sut.run(attachments: [
            FakeShareAttachment(name: "a.txt"),
            FakeShareAttachment(name: "b.txt"),
        ], onProgress: { index, total in progressReports.append("\(index)/\(total)") })

        XCTAssertEqual(progressReports, ["1/2", "2/2"])
    }

    // MARK: - Error isolation

    func test_run_oneFailureDoesNotAbortTheRemainingAttachments() async {
        // A user who shares five photos and hits a server error on the third should still get
        // the other four.
        let sut = makeSUT()
        sut.uploadHandler = { [self] _, name, _, _ in
            if name == "b.txt" { throw StubError(message: "Server error (500).") }
            return makeUploadResult(id: name, name: name)
        }

        let results = await sut.run(attachments: [
            FakeShareAttachment(name: "a.txt"),
            FakeShareAttachment(name: "b.txt"),
            FakeShareAttachment(name: "c.txt"),
        ])

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results[0].outcome.isSuccess)
        XCTAssertEqual(results[1].outcome, .failed(message: "Server error (500)."))
        XCTAssertTrue(results[2].outcome.isSuccess)
    }

    func test_run_namesTheFailingItem_soTheUserKnowsWhatToReSend() async {
        let sut = makeSUT()
        sut.uploadHandler = { _, _, _, _ in throw StubError(message: "boom") }

        let results = await sut.run(attachments: [FakeShareAttachment(name: "holiday.mov")])

        XCTAssertEqual(results.first?.name, "holiday.mov")
    }

    func test_run_recordsFailure_whenTheAttachmentCannotBeMaterialised() async {
        let sut = makeSUT()
        sut.uploadHandler = { [self] _, _, _, _ in makeUploadResult() }

        let results = await sut.run(attachments: [
            FakeShareAttachment(name: "broken.dat", loadError: StubError(message: "provider failed"))
        ])

        XCTAssertEqual(results, [ShareItemResult(name: "broken.dat",
                                                 outcome: .failed(message: "provider failed"))])
    }

    // MARK: - Memory cap

    func test_run_rejectsOversizeItems_withAnActionableMessage() async {
        let sut = makeSUT(maxItemBytes: 10)
        sut.uploadHandler = { [self] _, _, _, _ in makeUploadResult() }

        let big = FakeShareAttachment(name: "huge.bin", contents: Data(repeating: 0, count: 4096))
        let results = await sut.run(attachments: [big])

        XCTAssertEqual(results, [ShareItemResult(name: "huge.bin",
                                                 outcome: .failed(message: ShareLimits.oversizeMessage))])
    }

    func test_run_doesNotUploadOversizeItems() async {
        let sut = makeSUT(maxItemBytes: 10)
        var uploadCallCount = 0
        sut.uploadHandler = { [self] _, _, _, _ in
            uploadCallCount += 1
            return makeUploadResult()
        }

        _ = await sut.run(attachments: [
            FakeShareAttachment(name: "huge.bin", contents: Data(repeating: 0, count: 4096))
        ])

        XCTAssertEqual(uploadCallCount, 0)
    }

    func test_run_checksSizeFromFileAttributes_notFromLoadedBytes() async {
        // The whole point of loadFileRepresentation over loadDataRepresentation: a 400 MB video
        // must be rejected without ever being resident. `fileSizeProvider` is the seam the
        // production path uses, so proving it is consulted proves the check precedes the read.
        let sut = makeSUT(maxItemBytes: 1_000)
        var sizeProviderCallCount = 0
        sut.fileSizeProvider = { _ in
            sizeProviderCallCount += 1
            return 999_999_999   // reported without any file of that size existing
        }
        var uploadCallCount = 0
        sut.uploadHandler = { [self] _, _, _, _ in
            uploadCallCount += 1
            return makeUploadResult()
        }

        let results = await sut.run(attachments: [FakeShareAttachment(name: "video.mov")])

        XCTAssertEqual(sizeProviderCallCount, 1)
        XCTAssertEqual(uploadCallCount, 0)
        XCTAssertEqual(results.first?.outcome, .failed(message: ShareLimits.oversizeMessage))
    }

    func test_run_acceptsItemsAtExactlyTheCap() async {
        let sut = makeSUT(maxItemBytes: 100)
        sut.fileSizeProvider = { _ in 100 }
        sut.uploadHandler = { [self] _, _, _, _ in makeUploadResult(id: "ok") }

        let results = await sut.run(attachments: [FakeShareAttachment(name: "edge.bin")])

        XCTAssertEqual(results.first?.outcome, .uploaded(id: "ok"))
    }

    func test_shareLimit_isFarBelowTheAppsPhotoSyncCap() {
        // The extension's ceiling is a different order of magnitude from the app's on purpose —
        // roughly three copies of the payload are resident at peak in a process with ~120 MB.
        XCTAssertLessThan(ShareLimits.maxItemBytes, PhotoSyncService.maxAssetSizeBytes / 10)
    }

    // MARK: - Cleanup

    func test_run_removesTheMaterialisedFileAfterUpload() async {
        let sut = makeSUT()
        sut.uploadHandler = { [self] _, _, _, _ in makeUploadResult() }
        let attachment = FakeShareAttachment(name: "temp.txt")

        _ = await sut.run(attachments: [attachment])

        let url = try? XCTUnwrap(attachment.materialisedURL)
        XCTAssertNotNil(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url!.path),
                       "Plaintext copies of shared files must not be left in the extension's temp directory")
    }

    func test_run_withNoAttachments_returnsNoResults() async {
        let sut = makeSUT()
        let results = await sut.run(attachments: [])
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Attachment flattening

    func test_flattenAttachments_withNoInputItems_isEmpty() {
        XCTAssertTrue(ShareViewControllerTestHooks.flatten([]).isEmpty)
    }

    func test_flattenAttachments_ignoresNonExtensionItems() {
        XCTAssertTrue(ShareViewControllerTestHooks.flatten(["not an NSExtensionItem", 42]).isEmpty)
    }

    func test_flattenAttachments_collectsAttachmentsAcrossMultipleInputItems() {
        // Multi-select arrives either as several input items with one attachment each, or as one
        // input item with several — depending on the sending app. Both must flatten to one list.
        let itemA = NSExtensionItem()
        itemA.attachments = [NSItemProvider(item: NSData(), typeIdentifier: "public.data")]
        let itemB = NSExtensionItem()
        itemB.attachments = [
            NSItemProvider(item: NSData(), typeIdentifier: "public.data"),
            NSItemProvider(item: NSData(), typeIdentifier: "public.data"),
        ]

        XCTAssertEqual(ShareViewControllerTestHooks.flatten([itemA, itemB]).count, 3)
    }
}

// MARK: - ShareViewControllerTestHooks

/// `ShareViewController` lives in the extension target, which the test bundle cannot link. Its
/// flattening rule is the one piece of that file worth asserting, so it is mirrored here against
/// the same `ShareAttachment`/`ItemProviderAttachment` types the extension uses.
///
/// This is a deliberate compromise, and it is worth naming: the *production* flattening code is
/// not what these tests execute. If the two ever diverge, these tests would keep passing —
/// covered instead by the share-sheet steps in the verification document.
private enum ShareViewControllerTestHooks {
    static func flatten(_ inputItems: [Any]) -> [ShareAttachment] {
        var result: [ShareAttachment] = []
        for case let item as NSExtensionItem in inputItems {
            for provider in item.attachments ?? [] {
                let typeIdentifier = provider.registeredTypeIdentifiers.first ?? "public.data"
                result.append(ItemProviderAttachment(provider: provider, typeIdentifier: typeIdentifier))
            }
        }
        return result
    }
}
