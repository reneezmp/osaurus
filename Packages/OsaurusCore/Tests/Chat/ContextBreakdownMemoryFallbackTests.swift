import Testing

@testable import OsaurusCore

@Suite
struct ContextBreakdownMemoryFallbackTests {
    private func memoryTokens(in breakdown: ContextBreakdown) -> Int? {
        breakdown.context.first { $0.id == "memory" }?.tokens
    }

    @Test("preview fallback surfaces cached memory when no composed memory exists")
    func fallbackMemoryAppearsWithoutComposedMemory() {
        let breakdown = ContextBreakdown.from(
            context: ComposedContext(),
            fallbackMemoryTokens: 37
        )

        #expect(memoryTokens(in: breakdown) == 37)
    }

    @Test("no fallback adds no memory rail")
    func noFallbackAddsNoMemoryRail() {
        let breakdown = ContextBreakdown.from(context: ComposedContext())

        #expect(memoryTokens(in: breakdown) == nil)
    }

    @Test("composed memory replaces the preview fallback")
    func composedMemoryReplacesFallback() {
        let memory = "Remember the existing context, not the preview estimate."
        let breakdown = ContextBreakdown.from(
            context: ComposedContext(memorySection: memory),
            fallbackMemoryTokens: 37
        )

        #expect(memoryTokens(in: breakdown) == ContextBudgetManager.estimateTokens(for: memory))
    }

    @Test("an empty composed memory section suppresses the preview fallback")
    func emptyComposedMemorySuppressesFallback() {
        let breakdown = ContextBreakdown.from(
            context: ComposedContext(memorySection: ""),
            fallbackMemoryTokens: 37
        )

        #expect(memoryTokens(in: breakdown) == nil)
    }
}
