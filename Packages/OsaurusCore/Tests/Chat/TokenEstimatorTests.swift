import Testing

@testable import OsaurusCore

@Suite("Token estimator")
struct TokenEstimatorTests {
    @Test func preservesAsciiHeuristic() {
        #expect(TokenEstimator.estimate("abcdefgh") == 2)
        #expect(TokenEstimator.toolCallTokens(name: "tool", arguments: "{}", id: "id") == 7)
    }

    @Test func estimatesDenseUnicodeFromUtf8Bytes() {
        #expect(TokenEstimator.estimate("司法") == 1)
        #expect(TokenEstimator.estimate("司法判断") == 3)
    }
}
