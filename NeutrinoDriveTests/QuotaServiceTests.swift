import XCTest
@testable import NeutrinoDrive

/// Unit tests for QuotaService and the StorageQuota model.
/// Network calls are not made — tests exercise the synchronous/in-process paths only.
///
/// `refresh()` hits `GET /api/v1/drive/quota` and this repo's test convention (see
/// DownloadServiceTests.swift) does not stub URLSession/URLProtocol, so the live decode path
/// through `refresh()` is not exercised here. Instead, `StorageQuota`'s `Decodable`
/// conformance is exercised directly against a local JSON literal shaped like the real
/// backend response, per the plan's real backend contract for `GET /api/v1/drive/quota`.
@MainActor
final class QuotaServiceTests: XCTestCase {

    // MARK: - QuotaService initial state

    func test_initialState_quotaIsNil() {
        let sut = QuotaService()
        XCTAssertNil(sut.quota)
    }

    func test_initialState_isNotLoading() {
        let sut = QuotaService()
        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - StorageQuota decoding

    func test_storageQuota_decodesNumericQuota() throws {
        let json = """
        { "usedBytes": 123456, "dailyUploadBytes": 1000, "quotaBytes": 5000000000, "dailyCapBytes": null }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StorageQuota.self, from: json)

        XCTAssertEqual(decoded.usedBytes, 123456)
        XCTAssertEqual(decoded.quotaBytes, 5_000_000_000)
    }

    func test_storageQuota_decodesNullQuotaBytes_asUnlimited() throws {
        let json = """
        { "usedBytes": 123456, "dailyUploadBytes": 1000, "quotaBytes": null, "dailyCapBytes": null }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StorageQuota.self, from: json)

        XCTAssertEqual(decoded.usedBytes, 123456)
        XCTAssertNil(decoded.quotaBytes)
    }

    func test_storageQuota_decodesZeroUsedBytes() throws {
        let json = """
        { "usedBytes": 0, "dailyUploadBytes": 0, "quotaBytes": 5000000000, "dailyCapBytes": null }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StorageQuota.self, from: json)

        XCTAssertEqual(decoded.usedBytes, 0)
    }
}
