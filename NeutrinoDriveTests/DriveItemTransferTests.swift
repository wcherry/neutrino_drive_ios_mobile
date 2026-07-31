import XCTest
import UniformTypeIdentifiers
@testable import NeutrinoDrive

/// Tests for the Phase 6 iPad layer: multi-window scene state and drag/drop payloads.
///
/// What is **not** covered here, and why: the gestures themselves. A drag from Neutrino Drive
/// into Mail, or a drop from Files onto the list, requires two running apps and a touch
/// sequence, which XCTest cannot produce. So the pieces that can be wrong *silently* are
/// isolated and tested — type identifiers, MIME mapping, lazy decryption, scene-state coding —
/// and the gestures are runtime checks in the verification document.
final class DriveItemTransferTests: XCTestCase {

    private func file(_ name: String, mime: String?) -> DriveItem {
        DriveItem(id: "id-\(name)", name: name, type: .file, parentID: nil, size: 100,
                  modifiedAt: Date(), isTrashed: false, isShared: false, mimeType: mime)
    }

    private func folder(_ name: String) -> DriveItem {
        DriveItem(id: "folder", name: name, type: .folder, parentID: nil, size: nil,
                  modifiedAt: Date(), isTrashed: false, isShared: false, mimeType: nil)
    }

    // MARK: - Type identifiers

    func test_typeIdentifier_prefersMIMEType() {
        XCTAssertEqual(
            DriveItemTransfer.typeIdentifier(forMIMEType: "application/pdf", fileName: "a.pdf"),
            UTType.pdf.identifier
        )
        XCTAssertEqual(
            DriveItemTransfer.typeIdentifier(forMIMEType: "image/jpeg", fileName: "a.jpg"),
            UTType.jpeg.identifier
        )
    }

    /// A generic MIME type is common from this backend; the extension is more informative and
    /// decides whether Mail or Notes will accept the drop at all.
    func test_typeIdentifier_fallsBackToFileExtension() {
        XCTAssertEqual(
            DriveItemTransfer.typeIdentifier(forMIMEType: "application/octet-stream",
                                             fileName: "report.pdf"),
            UTType.pdf.identifier
        )
    }

    /// `UTType(mimeType:)` never returns nil for junk — it synthesises a `dyn.` placeholder that
    /// conforms to nothing. Advertising that would tell a receiving app less than `public.data`.
    func test_typeIdentifier_rejectsDynamicTypes() {
        let identifier = DriveItemTransfer.typeIdentifier(forMIMEType: "x/nonsense",
                                                          fileName: "mystery")
        XCTAssertEqual(identifier, UTType.data.identifier)
        XCTAssertFalse(identifier.hasPrefix("dyn."))
    }

    func test_canDrag_filesOnly() throws {
        try XCTSkipUnless(FeatureFlags.dragAndDrop, "feature disabled")
        XCTAssertTrue(DriveItemTransfer.canDrag(item: file("a.pdf", mime: "application/pdf")))
        // A folder has no single file to hand over; a recursive export is a different feature.
        XCTAssertFalse(DriveItemTransfer.canDrag(item: folder("Docs")))
    }

    // MARK: - MIME mapping for drops

    func test_mimeType_forTypeIdentifier() {
        XCTAssertEqual(
            DriveItemTransfer.mimeType(forTypeIdentifier: UTType.pdf.identifier, fileName: "a.pdf"),
            "application/pdf"
        )
        XCTAssertEqual(
            DriveItemTransfer.mimeType(forTypeIdentifier: UTType.png.identifier, fileName: "a.png"),
            "image/png"
        )
    }

    func test_mimeType_fallsBackToExtensionThenOctetStream() {
        XCTAssertEqual(
            DriveItemTransfer.mimeType(forTypeIdentifier: "not.a.real.type", fileName: "x.png"),
            "image/png"
        )
        XCTAssertEqual(
            DriveItemTransfer.mimeType(forTypeIdentifier: "not.a.real.type", fileName: "noext"),
            "application/octet-stream"
        )
    }

    // MARK: - Drag provider

    func test_makeItemProvider_advertisesCorrectTypeAndName() throws {
        try XCTSkipUnless(FeatureFlags.dragAndDrop, "feature disabled")
        let item = file("Report.pdf", mime: "application/pdf")
        let provider = DriveItemTransfer.makeItemProvider(for: item) { _ in
            XCTFail("must not decrypt while merely constructing the provider")
            return URL(fileURLWithPath: "/dev/null")
        }

        XCTAssertEqual(provider.suggestedName, "Report.pdf")
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains(UTType.pdf.identifier),
                      "got \(provider.registeredTypeIdentifiers)")
    }

    /// **The property that keeps dragging a 2 GB video cheap.** Building the provider must not
    /// download or decrypt anything; that happens only if a drop actually occurs.
    func test_makeItemProvider_doesNotDecryptUntilDropped() throws {
        try XCTSkipUnless(FeatureFlags.dragAndDrop, "feature disabled")
        var loadCount = 0
        let item = file("Big.mov", mime: "video/quicktime")

        let provider = DriveItemTransfer.makeItemProvider(for: item) { _ in
            loadCount += 1
            return URL(fileURLWithPath: "/dev/null")
        }
        _ = provider.registeredTypeIdentifiers

        XCTAssertEqual(loadCount, 0, "constructing a drag must not trigger a download")
    }

    /// And when a drop does happen, the file is produced through the injected loader — which in
    /// production is `DownloadService`, i.e. the **authenticated** decrypt path.
    func test_makeItemProvider_loadsFileOnlyWhenRequested() async throws {
        try XCTSkipUnless(FeatureFlags.dragAndDrop, "feature disabled")
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = tempDir.appendingPathComponent("Report.pdf")
        try Data("decrypted".utf8).write(to: source)

        let item = file("Report.pdf", mime: "application/pdf")
        let provider = DriveItemTransfer.makeItemProvider(for: item) { _ in source }

        let loaded = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
        XCTAssertEqual(String(data: loaded, encoding: .utf8), "decrypted")
    }

    // MARK: - Document window state

    /// Scene state is persisted by iOS and handed back after a relaunch, so it must survive a
    /// Codable round trip intact.
    func test_documentWindowValue_roundTripsThroughCoding() throws {
        let original = DocumentWindowValue(fileID: "abc", name: "Report.pdf",
                                           mimeType: "application/pdf")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DocumentWindowValue.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.fileID, "abc")
        XCTAssertEqual(decoded.name, "Report.pdf")
        XCTAssertEqual(decoded.mimeType, "application/pdf")
    }

    func test_documentWindowValue_handlesNilMIMEType() throws {
        let original = DocumentWindowValue(fileID: "x", name: "unknown", mimeType: nil)
        let decoded = try JSONDecoder().decode(DocumentWindowValue.self,
                                               from: try JSONEncoder().encode(original))
        XCTAssertNil(decoded.mimeType)
    }

    /// A restored window rebuilds its viewer from the persisted value alone, before any drive
    /// listing has loaded — so the placeholder must carry the fields the viewer branches on.
    func test_documentWindowValue_placeholderItemPreservesViewerInputs() {
        let value = DocumentWindowValue(fileID: "vid", name: "Movie.mov", mimeType: "video/quicktime")
        let item = value.placeholderItem

        XCTAssertEqual(item.id, "vid")
        XCTAssertEqual(item.name, "Movie.mov")
        XCTAssertEqual(item.mimeType, "video/quicktime")
        XCTAssertEqual(item.type, .file)
        XCTAssertTrue(StreamingPlaybackService.isStreamableMedia(mimeType: item.mimeType))
    }

    func test_documentWindowValue_isDerivedFromDriveItem() {
        let item = file("Notes.txt", mime: "text/plain")
        let value = DocumentWindowValue(item: item)
        XCTAssertEqual(value.fileID, item.id)
        XCTAssertEqual(value.name, item.name)
        XCTAssertEqual(value.mimeType, item.mimeType)
    }

    /// The scene identifier is shared between the `WindowGroup` declaration and every
    /// `openWindow` call; a mismatch would silently open nothing.
    func test_documentWindowScene_identifierIsStable() {
        XCTAssertEqual(DocumentWindowScene.identifier, "neutrino.document")
    }
}
