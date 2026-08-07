import Foundation

// MARK: - SearchIndexTokenizer

/// Splits text into the terms the local search index stores.
///
/// A Swift port of the web app's `packages/search/src/tokenizer.ts`, kept behaviourally
/// identical — NFC-normalized, lowercased, punctuation stripped to whitespace — so a term
/// produced on one platform is byte-identical to the same word tokenized on another. That
/// matters because snapshots sync between devices (`agent_docs/search.md` in the `neutrino`
/// repo): a term iOS writes has to be found by a prefix scan a web client runs, and vice versa.
enum SearchIndexTokenizer {

    struct TermPositions {
        let term: String
        let positions: [Int]
    }

    /// Lowercased, punctuation-stripped words, deduplicated, first-occurrence order.
    static func normalizeText(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in splitWords(text) where seen.insert(word).inserted {
            result.append(word)
        }
        return result
    }

    /// Every distinct term in `text`, with the word offsets it appears at — the input to
    /// building postings for one document's title or content.
    static func tokenizeWithPositions(_ text: String) -> [TermPositions] {
        let words = splitWords(text)
        var order: [String] = []
        var positions: [String: [Int]] = [:]
        for (i, word) in words.enumerated() {
            if positions[word] == nil { order.append(word) }
            positions[word, default: []].append(i)
        }
        return order.map { TermPositions(term: $0, positions: positions[$0] ?? []) }
    }

    /// NFC-normalize, lowercase, then split on any run of characters that is not a Unicode
    /// letter or number — the Swift equivalent of the web's `/[^\p{L}\p{N}\s]/gu` strip
    /// followed by a whitespace split.
    private static func splitWords(_ text: String) -> [String] {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
