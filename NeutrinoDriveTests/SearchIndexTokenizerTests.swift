import XCTest
@testable import NeutrinoDrive

final class SearchIndexTokenizerTests: XCTestCase {

    // MARK: - normalizeText

    func test_normalizeText_lowercasesAndDeduplicates() {
        let words = SearchIndexTokenizer.normalizeText("Report Report REPORT")
        XCTAssertEqual(words, ["report"])
    }

    func test_normalizeText_stripsPunctuationToWhitespace() {
        let words = SearchIndexTokenizer.normalizeText("foo-bar.baz")
        XCTAssertEqual(words, ["foo", "bar", "baz"])
    }

    func test_normalizeText_emptyStringYieldsNoWords() {
        XCTAssertTrue(SearchIndexTokenizer.normalizeText("").isEmpty)
    }

    func test_normalizeText_preservesFirstOccurrenceOrder() {
        let words = SearchIndexTokenizer.normalizeText("zebra apple zebra mango apple")
        XCTAssertEqual(words, ["zebra", "apple", "mango"])
    }

    // MARK: - tokenizeWithPositions

    func test_tokenizeWithPositions_tracksWordOffsets() {
        let terms = SearchIndexTokenizer.tokenizeWithPositions("the quick brown fox")
        let map = Dictionary(uniqueKeysWithValues: terms.map { ($0.term, $0.positions) })
        XCTAssertEqual(map["the"], [0])
        XCTAssertEqual(map["quick"], [1])
        XCTAssertEqual(map["brown"], [2])
        XCTAssertEqual(map["fox"], [3])
    }

    func test_tokenizeWithPositions_repeatedWordCollectsAllOffsets() {
        let terms = SearchIndexTokenizer.tokenizeWithPositions("report the report on reports")
        let report = terms.first { $0.term == "report" }
        XCTAssertEqual(report?.positions, [0, 2])
    }

    func test_tokenizeWithPositions_emptyTextYieldsNoTerms() {
        XCTAssertTrue(SearchIndexTokenizer.tokenizeWithPositions("").isEmpty)
    }
}
