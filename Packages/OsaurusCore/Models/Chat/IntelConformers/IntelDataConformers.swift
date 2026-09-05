//
//  IntelDataConformers.swift
//  OsaurusCore
//
//  M10 Phase 4d: Intel-lite data type conformers for ChatView protocols.
//

#if OSAURUS_INTEL

import Combine
import Foundation
import SwiftUI

// MARK: - ChatTurn

final class ChatTurn: ChatTurnProtocol, ObservableObject, Identifiable, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    let createdAt: Date
    var completedAt: Date?

    @Published var content: String {
        didSet { _contentLength = content.count }
    }
    var contentLength: Int { _contentLength }
    private var _contentLength: Int

    var contentIsEmpty: Bool { _contentLength == 0 }
    var contentIsBlank: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Published var thinking: String {
        didSet { _thinkingLength = thinking.count }
    }
    var thinkingLength: Int { _thinkingLength }
    private var _thinkingLength: Int

    var thinkingIsEmpty: Bool { _thinkingLength == 0 }
    var thinkingIsBlank: Bool {
        thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasThinking: Bool { _thinkingLength > 0 }
    var hasRenderableThinking: Bool { hasThinking && !thinkingIsBlank }

    @Published var attachments: [Attachment] = []
    @Published var toolCalls: [ToolCall]? = nil
    var toolCallId: String? = nil
    @Published var toolResults: [String: String] = [:]

    var pendingToolName: String? = nil
    var pendingToolArgPreview: String? = nil
    var pendingToolArgSize: Int = 0
    var pendingToolArgFragmentCount: Int = 0
    var preflightCapabilities: Any? = nil

    var timeToFirstToken: TimeInterval?
    var generationTokensPerSecond: Double?
    var generationTokenCount: Int?
    var unclosedReasoning: Bool = false

    var turnId: UUID? { id }
    var imageData: Data? { nil }
    var hasAttachments: Bool { !attachments.isEmpty }
    var visibleContent: String { content }

    init(role: MessageRole, content: String, attachments: [Attachment] = [], id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.content = content
        self._contentLength = content.count
        self.thinking = ""
        self._thinkingLength = 0
        self.attachments = attachments
        self.completedAt = role == .user ? Date() : nil
    }

    convenience init(from turn: any ChatTurnProtocol) {
        self.init(role: turn.role, content: turn.content, attachments: turn.attachments, id: turn.id, createdAt: turn.createdAt)
        self.completedAt = turn.completedAt
        self.toolCalls = turn.toolCalls
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
    }

    func appendContent(_ s: String) {
        guard !s.isEmpty else { return }
        content += s
    }

    func appendContentAndNotify(_ s: String) {
        appendContent(s)
        objectWillChange.send()
    }

    func appendThinking(_ s: String) {
        guard !s.isEmpty else { return }
        thinking += s
    }

    func appendThinkingAndNotify(_ s: String) {
        appendThinking(s)
        objectWillChange.send()
    }

    func notifyContentChanged() {
        objectWillChange.send()
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {
        pendingToolArgPreview = nil
        pendingToolArgSize = 0
        pendingToolArgFragmentCount = 0
    }

    func appendToolArgFragment(_ fragment: String) {
        pendingToolArgSize += fragment.utf8.count
        pendingToolArgFragmentCount += 1
        // Accumulate a bounded preview so the in-flight tool card can show the
        // query (args) building up live, not just the bare tool name.
        if (pendingToolArgPreview?.count ?? 0) < 600 {
            pendingToolArgPreview = (pendingToolArgPreview ?? "") + fragment
        }
    }

    func trimTrailingFunctionCallLeakage(toolName: String) {}

    static func == (lhs: ChatTurn, rhs: ChatTurn) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Attachment
//
// `Models/Chat/Attachment.swift` is now compiled directly on Intel
// (removed from Package.swift's exclude list as part of Phase 8C-prep).
// The old `struct Attachment: AttachmentProtocol, ...` stub that used to
// live here is gone — the real 525-line upstream definition with the
// `Kind` enum (image/document/audio/video plus spillover refs) and the
// full Codable surface is what Intel sees now.

// MARK: - VLMDetection (Intel stub)
//
// Upstream `Models/Configuration/MLXModel.swift` lives behind the
// excluded MLX layer, so `VLMDetection.isVLM(at:)` (used by upstream
// `ModelInfo.swift` to mark local Vision-Language models) is amputated
// on Intel. Always-false stub: Intel has no local models, no VLMs.
enum VLMDetection {
    static func isVLM(at directory: URL) -> Bool { false }
}

// MARK: - DirectoryPickerService (Intel stub)
//
// Upstream's `Services/DirectoryPickerService.swift` is excluded
// because it drives the local-model directory picker (NSOpenPanel +
// the on-disk MLX cache). Intel has no local cache to point at, but
// `ModelInfo.findModelDirectory` still calls it as part of its
// directory-scan path. Stub returns `~/.osaurus/models` so it has a
// valid URL to traverse (the directory just won't ever exist on
// Intel — `fileExists` returns false and the scan bails).
enum DirectoryPickerService {
    static func effectiveModelsDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".osaurus/models", isDirectory: true)
    }
}

// MARK: - LocalReasoningCapability (Intel stub)
//
// Upstream's `Services/LocalReasoningCapability.swift` introspects
// the local MLX model's tokenizer / template to decide whether it
// supports thinking-toggle. Intel has no local models, so the
// always-no-thinking capability is the correct answer — keeps
// `AutoThinkingProfile.matches()` from ever firing on Intel.
enum LocalReasoningCapability {
    struct Capability {
        let isToggleableThinking: Bool
    }
    static func capability(forModelId modelId: String) -> Capability {
        Capability(isToggleableThinking: false)
    }
}

// Note: the Phase 8C-prep-2 `NSImage.pngData()` shim that used to live
// here has been removed in Phase 8C-main because FloatingInputCard.swift
// is now un-body-swapped and its own `extension NSImage` brings the
// helper into scope for the whole Intel module.

// NOTE: `AttachmentBlobStore` is now the REAL upstream type — un-excluded
// in M11 Phase 11.B.1 (it imports only CryptoKit/Foundation/os, no
// amputated deps). The throw-only Intel stub that used to live here was
// removed; the real `read(_:)` serves the same call sites.

// MARK: - ContentBlock

enum BlockPosition: Equatable {
    case only, first, middle, last
}

struct ToolCallItem: Equatable {
    let call: ToolCall
    let result: String?
    static func == (lhs: ToolCallItem, rhs: ToolCallItem) -> Bool {
        lhs.call.id == rhs.call.id && lhs.result == rhs.result
    }
}

struct PreflightCapabilityItem: Equatable, Sendable {
    enum CapabilityType: String, Equatable, Sendable {
        case method, tool, skill

        var icon: String {
            switch self {
            case .method: return "doc.text"
            case .tool: return "wrench"
            case .skill: return "lightbulb"
            }
        }
    }

    let id: String = ""
    let name: String = ""
    let type: CapabilityType = .tool
    let description: String = ""
}

enum ContentBlockKind: Equatable {
    case header(role: MessageRole, agentName: String, isFirstInGroup: Bool)
    case paragraph(index: Int, text: String, isStreaming: Bool, role: MessageRole)
    case toolCallGroup(calls: [ToolCallItem])
    case thinking(index: Int, text: String, isStreaming: Bool)
    case userMessage(text: String, attachments: [Attachment])
    case sharedArtifact(artifact: SharedArtifact)
    case pendingToolCall(toolName: String, argPreview: String?, argSize: Int)
    case preflightCapabilities(items: [PreflightCapabilityItem])
    case generationStats(ttft: TimeInterval?, tokensPerSecond: Double?, tokenCount: Int?, unclosedReasoning: Bool)
    case typingIndicator
    case groupSpacer
    case chart(spec: ChartSpec)
    case assistantActions(turnId: UUID)

    static func == (lhs: ContentBlockKind, rhs: ContentBlockKind) -> Bool {
        switch (lhs, rhs) {
        case let (.header(lRole, lName, lFirst), .header(rRole, rName, rFirst)):
            return lRole == rRole && lName == rName && lFirst == rFirst
        case let (.paragraph(lIdx, lText, lStream, lRole), .paragraph(rIdx, rText, rStream, rRole)):
            return lIdx == rIdx && lText == rText && lStream == rStream && lRole == rRole
        case let (.toolCallGroup(lCalls), .toolCallGroup(rCalls)):
            return lCalls == rCalls
        case let (.thinking(lIdx, lText, lStream), .thinking(rIdx, rText, rStream)):
            return lIdx == rIdx && lText == rText && lStream == rStream
        case let (.userMessage(lText, lAttach), .userMessage(rText, rAttach)):
            return lText == rText && lAttach.count == rAttach.count
        case let (.sharedArtifact(lArt), .sharedArtifact(rArt)):
            return lArt == rArt
        case let (.pendingToolCall(lName, _, lSize), .pendingToolCall(rName, _, rSize)):
            return lName == rName && lSize == rSize
        case let (.preflightCapabilities(lItems), .preflightCapabilities(rItems)):
            return lItems == rItems
        case let (.generationStats(lTtft, lTps, lCount, lUnclosed), .generationStats(rTtft, rTps, rCount, rUnclosed)):
            return lTtft == rTtft && lTps == rTps && lCount == rCount && lUnclosed == rUnclosed
        case (.typingIndicator, .typingIndicator), (.groupSpacer, .groupSpacer): return true
        case let (.chart(lSpec), .chart(rSpec)): return lSpec == rSpec
        case let (.assistantActions(lId), .assistantActions(rId)): return lId == rId
        default: return false
        }
    }
}

struct ContentBlock: Identifiable, Equatable, @unchecked Sendable {
    let id: String
    let turnId: UUID
    let kind: ContentBlockKind
    var position: BlockPosition = .only

    var role: MessageRole {
        switch kind {
        case let .header(role, _, _): return role
        case let .paragraph(_, _, _, role): return role
        case .toolCallGroup, .thinking, .sharedArtifact, .pendingToolCall, .preflightCapabilities,
             .generationStats, .typingIndicator, .groupSpacer, .chart, .assistantActions:
            return .assistant
        case .userMessage: return .user
        }
    }
}

// MARK: - ModelOptionValue
//
// Now provided by upstream `Models/Configuration/ModelOptions.swift`
// (un-excluded as part of Phase 8C-prep-2). The Intel `struct
// ModelOptionValue` stub that used to live here has been removed.

// MARK: - ChatTurnData

struct ChatTurnData: ChatTurnProtocol, ChatTurnDataProtocol, @unchecked Sendable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    var attachments: [Attachment] = []
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolResults: [String: String]
    var thinking: String
    let createdAt: Date
    var completedAt: Date?
    var generationTokenCount: Int?
    var timeToFirstToken: TimeInterval?
    var generationTokensPerSecond: Double?
    var pendingToolName: String?
    var pendingToolArgFragmentCount: Int = 0
    var unclosedReasoning: Bool = false
    var preflightCapabilities: Any? = nil

    var turnId: UUID? { id }
    var imageData: Data? { nil }
    var hasRenderableThinking: Bool { !thinking.isEmpty }
    var hasThinking: Bool { !thinking.isEmpty }
    var contentIsBlank: Bool { content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var thinkingIsBlank: Bool { thinking.isEmpty }
    var contentIsEmpty: Bool { content.isEmpty }
    var contentLength: Int { content.count }
    var visibleContent: String { content }

    init(from turn: any ChatTurnProtocol) {
        self.id = turn.id
        self.role = turn.role
        self.content = turn.content
        self.attachments = turn.attachments
        self.toolCalls = turn.toolCalls
        self.toolCallId = turn.toolCallId
        self.toolResults = turn.toolResults
        self.thinking = turn.thinking
        self.createdAt = turn.createdAt
        self.completedAt = turn.completedAt
        self.generationTokenCount = turn.generationTokenCount
        self.timeToFirstToken = turn.timeToFirstToken
        self.generationTokensPerSecond = turn.generationTokensPerSecond
        self.preflightCapabilities = turn.preflightCapabilities
    }

    static func == (lhs: ChatTurnData, rhs: ChatTurnData) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }

    func consolidateContent() {}
    func clearPendingToolArgs() {}
    func appendToolArgFragment(_ arg: String) {}

    // M13 follow-up (Renée 2026-06-04): memberwise init so the Codable
    // initializer below (and any in-place construction) can build a turn
    // without going through `init(from: any ChatTurnProtocol)`.
    init(
        id: UUID,
        role: MessageRole,
        content: String,
        attachments: [Attachment] = [],
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil,
        toolResults: [String: String] = [:],
        thinking: String = "",
        createdAt: Date,
        completedAt: Date? = nil,
        generationTokenCount: Int? = nil,
        timeToFirstToken: TimeInterval? = nil,
        generationTokensPerSecond: Double? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolResults = toolResults
        self.thinking = thinking
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.generationTokenCount = generationTokenCount
        self.timeToFirstToken = timeToFirstToken
        self.generationTokensPerSecond = generationTokensPerSecond
    }
}

// MARK: - ChatTurnData Codable (M13 session persistence on Intel)
//
// Hand-rolled so the transient `preflightCapabilities: Any?` (live preflight
// state, not persistable) and the streaming-only `pending*` / `unclosedReasoning`
// scratch fields are skipped — they reconstruct to defaults on load. Everything
// that defines the conversation (role, content, attachments, tool calls/results,
// thinking, timing) round-trips.
extension ChatTurnData: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, content, attachments, toolCalls, toolCallId, toolResults
        case thinking, createdAt, completedAt, generationTokenCount
        case timeToFirstToken, generationTokensPerSecond
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            role: try c.decode(MessageRole.self, forKey: .role),
            content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
            attachments: try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [],
            toolCalls: try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls),
            toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId),
            toolResults: try c.decodeIfPresent([String: String].self, forKey: .toolResults) ?? [:],
            thinking: try c.decodeIfPresent(String.self, forKey: .thinking) ?? "",
            createdAt: try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            completedAt: try c.decodeIfPresent(Date.self, forKey: .completedAt),
            generationTokenCount: try c.decodeIfPresent(Int.self, forKey: .generationTokenCount),
            timeToFirstToken: try c.decodeIfPresent(TimeInterval.self, forKey: .timeToFirstToken),
            generationTokensPerSecond: try c.decodeIfPresent(
                Double.self, forKey: .generationTokensPerSecond)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        if !toolResults.isEmpty { try c.encode(toolResults, forKey: .toolResults) }
        if !thinking.isEmpty { try c.encode(thinking, forKey: .thinking) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encodeIfPresent(generationTokenCount, forKey: .generationTokenCount)
        try c.encodeIfPresent(timeToFirstToken, forKey: .timeToFirstToken)
        try c.encodeIfPresent(generationTokensPerSecond, forKey: .generationTokensPerSecond)
    }
}

// MARK: - Type aliases

// Agent from Agent.swift is NOT excluded; add conformance to AgentInfoProtocol
extension Agent: AgentInfoProtocol {}

final class AppConfiguration: ObservableObject, @unchecked Sendable {
    static let shared = AppConfiguration()
    @Published var chatConfig = AppChatConfigStub()
    var foundationModelAvailable: Bool { false }
}
struct AppChatConfigStub: Sendable {
    var generativeGreetingsEnabled = false
    var greetingPersona = ""
    var disableTools = false
    var maxToolAttempts = 5
    var topPOverride: Double? = nil
    /// Tracks the upstream `AppConfiguration.chatConfig.enableClipboardMonitoring`
    /// toggle. Intel reads it from `FloatingInputCard`'s paste-monitor wiring.
    /// Defaults true so clipboard paste works by default on Intel; users can
    /// opt-out via the same Settings → Chat row that exists on Apple Silicon.
    var enableClipboardMonitoring = true
}

final class CapabilityLoadBuffer: @unchecked Sendable { static let shared = CapabilityLoadBuffer(); func loadInBackground() {}; func drain() -> [IntelTool] { [] } }

/// Intel ChatConfigurationStore. Folds the passed instance into the shared
/// singleton AND persists it to `~/.osaurus/config/chat.json` via
/// `ChatConfiguration.persistToDisk()` — so Settings (core model, temperature,
/// max tokens, context length, …) now survive app restart. The singleton loads
/// the same file on first access (`ChatConfiguration.shared`). Keys match
/// upstream's format so a migrated/Apple-Silicon file round-trips.
final class ChatConfigurationStore: @unchecked Sendable {
    static func load() -> ChatConfiguration { ChatConfiguration.shared }

    /// Persists by folding the passed instance's fields into the
    /// shared singleton. On Intel `ChatConfiguration` is a class
    /// (not a value type like upstream), so the view-side pattern of
    /// `let cfg = ChatConfiguration(...); save(cfg)` produces a NEW
    /// instance — without this fold, mutations would be discarded.
    /// On-disk persistence on Intel is M11 follow-up; the singleton
    /// fold gives session-scoped persistence which is enough for
    /// the view's two-way bindings to round-trip.
    static func save(_ config: ChatConfiguration) {
        if config !== ChatConfiguration.shared {
            ChatConfiguration.shared.adopt(config)
        }
        // Persist to ~/.osaurus/config/chat.json so Settings survive restart.
        ChatConfiguration.shared.persistToDisk()
    }
}


final class ChatSessionExportCoordinator: @unchecked Sendable { static let shared = ChatSessionExportCoordinator() }

struct ClarifyPromptState: Sendable {
    init(question: String = "", options: [String] = [], allowMultiple: Bool = false, onSubmit: ((String) -> Void)? = nil) {}
    func cancel() {}
}

struct SecretPromptState: Sendable {
    init() {}
    init(key: String = "", description: String = "", instructions: String = "", agentId: UUID? = nil, onSubmit: ((String) -> Void)? = nil) {}
    var key: String { "" }
    var description: String { "" }
    var instructions: String { "" }
    var agentId: UUID? { nil }
    func cancel() {}
}

struct ClarifyTool: Sendable { init() {}; static func parse(argumentsJSON json: String) -> ClarifyPayload? { nil } }

// M12 Gap 2/3: the real `FolderContextService` (Folder/FolderContextService.swift)
// is un-excluded — it drives the NSOpenPanel folder picker and registers the
// folder tool suite via FolderToolManager. The amputated directory-watcher /
// indexing pieces inside it are gated separately; the picker + tool wiring are
// pure AppKit/Foundation. The old no-op Intel stub that lived here is removed.

struct ImageFullScreenView: View { var image: Any? = nil; var altText: String = ""; var body: some View { EmptyView() } }

extension View {
    func imageFullScreenSheetPresentation() -> some View {
        // NOTE: macOS 15's `.presentationSizing(.fitted)` was dropped for
        // Ventura/Sonoma compatibility; the ideal frame below sizes the sheet
        // sensibly on all supported OSes.
        frame(
            minWidth: 320,
            idealWidth: 960,
            maxWidth: .infinity,
            minHeight: 240,
            idealHeight: 720,
            maxHeight: .infinity
        )
    }
}

final class MemoryContextAssembler: @unchecked Sendable {
    static let shared = MemoryContextAssembler()

    /// Best-effort preview of what `MemorySearchService.recall(...)` (the
    /// real per-turn recall path, `IntelMemoryConformers.swift`, invoked
    /// from `composeChatContext` in this file) would inject. Feeds
    /// `ChatView.refreshMemoryTokens()`'s context-budget popover estimate —
    /// never used to build an actual outgoing prompt.
    ///
    /// Previously this hard-returned `nil` unconditionally, so the popover's
    /// memory row always read 0 tokens even while recall was genuinely
    /// injecting content via the real send path. That silent-zero bug is
    /// what this replaces.
    ///
    /// LIMITATION, read before treating a mismatch as a new bug: this call
    /// site has no query string — `refreshMemoryTokens` runs on session
    /// load / agent switch / config change, not per keystroke, and the
    /// signature here (fixed by other call sites: `ChatView.swift`,
    /// `Views/Memory/MemoryView.swift`, `Tests/Memory/MemoryTests.swift`)
    /// takes no query param to add one. Real recall requires a non-empty
    /// query and returns `nil` without one (see `MemorySearchService.recall`'s
    /// own guard) — so an exact estimate is not obtainable here by
    /// construction, not by omission. What this DOES estimate honestly:
    ///   - Layer 1 (Identity): query-independent in real recall too —
    ///     reproduced exactly (same overrides + content, same char caps).
    ///   - Layers 2-3 (pinned facts / episodes): approximated using the
    ///     same per-layer counts recall requests (topK 6 / 4), ordered by
    ///     salience / recency (`MemoryDatabase`'s natural ordering) instead
    ///     of a real semantic query match — a stand-in for "what's
    ///     typically available to recall," not "what the next turn's actual
    ///     query will surface." Can read higher or lower than the real
    ///     per-turn number.
    ///   - Layer 4 (raw transcript fallback) is NOT estimated: it is the
    ///     most query-sensitive layer and the shakiest to fake without one,
    ///     so it is left out rather than guessed at. The estimate therefore
    ///     tends to undercount on turns where transcript filler would
    ///     otherwise be injected — documented instead of hidden.
    ///
    /// `agentId` is accepted for call-site parity but intentionally NOT
    /// used to scope the read: the real send path calls
    /// `MemorySearchService.shared.recall(agentId: nil, ...)` on purpose
    /// (`docs/MEMORY_PLAN.md` §1: "Recall ignores agent scoping" is
    /// documented, deliberate behavior, not a bug for this file to paper
    /// over). Matching that means every agent's memory contributes to the
    /// estimate, same as it would to the real injected block.
    static func assembleContext(agentId: String = "", config: Any? = nil) async -> Any? {
        let cfg = (config as? MemoryConfiguration) ?? MemoryConfigurationStore.load()
        guard cfg.enabled else { return nil }

        let db = MemoryDatabase.shared
        guard db.isOpen else { return nil }

        var charBudget = max(200, cfg.memoryBudgetTokens) * MemoryConfiguration.charsPerToken
        var blocks: [String] = []

        // Layer 1: Identity — exact reproduction of recall()'s Layer 1.
        if let identity = try? db.loadIdentity() {
            var idLines: [String] = []
            for override in identity.overrides.prefix(12) {
                let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let line = "- \(trimmed)"
                guard line.count <= charBudget else { break }
                charBudget -= line.count
                idLines.append(line)
            }
            let content = identity.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                let snippet = String(content.prefix(min(charBudget, 600)))
                if !snippet.isEmpty, snippet.count <= charBudget {
                    charBudget -= snippet.count
                    idLines.append(snippet)
                }
            }
            if !idLines.isEmpty {
                blocks.append("### About you\n" + idLines.joined(separator: "\n"))
            }
        }

        // Layer 2: Pinned facts — approximated by salience ordering (no
        // query available here; see limitation note above).
        let pinned = (try? db.loadPinnedFacts(agentId: nil, limit: 6)) ?? []
        let pinnedLines = Self.budgetedLines(
            pinned.map { "- \($0.content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))" },
            budget: &charBudget)
        if !pinnedLines.isEmpty {
            blocks.append("### Things to remember\n" + pinnedLines.joined(separator: "\n"))
        }

        // Layer 3: Episodes — approximated by recency ordering (same
        // reasoning as Layer 2).
        let days = cfg.episodeRetentionDays > 0 ? cfg.episodeRetentionDays : 3650
        let episodes = (try? db.loadEpisodes(agentId: nil, days: days, limit: 4)) ?? []
        let episodeLines = Self.budgetedLines(
            episodes.map {
                "- [\($0.conversationAt.prefix(10))] \($0.summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))"
            },
            budget: &charBudget)
        if !episodeLines.isEmpty {
            blocks.append("### Past sessions\n" + episodeLines.joined(separator: "\n"))
        }

        // Layer 4 (raw transcript fallback) intentionally omitted — see
        // limitation note above.

        guard !blocks.isEmpty else { return nil }
        return "## Relevant memory (estimate)\n" + blocks.joined(separator: "\n\n")
    }

    /// Take candidate lines in order until the shared character budget is
    /// spent. Mirrors `MemorySearchService.budgetedLines` exactly
    /// (duplicated rather than shared because that method is `private` on
    /// a type in a different, excluded-from-editing file).
    private static func budgetedLines(_ candidates: [String], budget: inout Int) -> [String] {
        var out: [String] = []
        for line in candidates where !line.isEmpty {
            guard line.count <= budget else { break }
            budget -= line.count
            out.append(line)
        }
        return out
    }
}
// `MemorySearchService` (real Intel implementation) lives in
// `IntelMemoryConformers.swift` — it embeds transcript turns and does cosine
// recall over the SQLCipher-backed transcript table.

// `ModelOptionsStore` and `ModelProfileRegistry` are now provided by
// upstream (un-excluded as part of Phase 8C-prep-2). The Intel stubs
// that used to live here have been removed.
final class ModelRuntime: @unchecked Sendable {
    static let shared = ModelRuntime()
    func unloadModelsNotIn(_ names: Set<String>) {}
    var runtimeSettings: Any? { nil }

    /// Background pre-encode hook the upstream FloatingInputCard calls so
    /// MLX can warm the audio encoder while the user is still recording.
    /// Intel has no resident MLX model, so we always return a `.skipped`
    /// result — the caller logs it and moves on. Signature mirrors
    /// upstream (non-optional return) so the chained `.status.rawValue`
    /// access at the call site type-checks unchanged.
    func preencodeLiveVoiceAudioIfResident(
        modelName: String,
        attachmentId: UUID,
        samples: [Float],
        sampleRate: Int
    ) async -> LiveVoicePreencodeResult {
        LiveVoicePreencodeResult(
            status: .skipped,
            sampleCount: samples.count,
            sampleRate: sampleRate,
            encodeMs: 0,
            message: "MLX preencode amputated on Intel"
        )
    }
}

final class PluginInstructionsResolver: @unchecked Sendable { static let shared = PluginInstructionsResolver(); static func instructions(pluginId: String, agentId: Any? = nil) -> String? { nil } }

final class SandboxAgentProvisioner: @unchecked Sendable { static let shared = SandboxAgentProvisioner(); static func linuxName(for agentId: String) -> String { "agent" } }
final class SandboxToolRegistrar: @unchecked Sendable {
    static let shared = SandboxToolRegistrar()
    func registerTools(for agentId: UUID) async {}
    /// FloatingInputCard's sandbox chip calls this when the user
    /// clicks "Retry" after a provisioning failure. Intel has no
    /// failures to reset (no provisioning ever happens), so no-op.
    /// `for:` arg is optional to match both upstream call shapes
    /// (`resetStartupFailures()` and `resetStartupFailures(for:)`).
    func resetStartupFailures(for agentId: UUID? = nil) {}
}

struct SecretPromptParser: Sendable {
    init() {}
    static func parse(_ text: String) -> SecretPromptState? { nil }
}
struct SecretToolResult: Sendable {
    init() {}
    static func stored(key: String) -> String { "" }
    static func cancelled(key: String) -> String { "" }
}

enum SessionCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case vision
    case voice
    case code
    case search

    var iconName: String {
        switch self {
        case .vision: return "eye.fill"
        case .voice: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .vision: return "Vision"
        case .voice: return "Voice"
        case .code: return "Code"
        case .search: return "Search"
        }
    }

    /// No-op derive used by the Intel `ChatSession` path. Capability badges
    /// stay empty on Intel until a fuller turn-inspection pipeline lands.
    static func derive(from turnData: Any? = nil) -> Set<SessionCapability> { [] }
}
struct SessionToolState: Sendable {
    init() {}
    static func fingerprint(executionMode: Any?, toolMode: Any?) -> String { "" }
    var initialPreflight: Any? { nil }
    var loadedToolNames: [String]? { nil }
    var initialAlwaysLoadedNames: Any? { nil }
}

struct IntelSkillInfo: Sendable {
    let id: UUID
    let name: String
}

// `SkillsView` (un-body-swapped in M11 Phase 11.A.2) reads
// `skillManager.skills`, `skillManager.isRefreshing`,
// `skillManager.enabledCount`, and mutates via the full CRUD
// surface — `create`, `update`, `delete`, `setEnabled`, `refresh`,
// `importSkill(from:)`, `importSkillFromMarkdown(_:)`,
// `importSkillsFromMarkdown(_:)`, `importSkillFromZip(_:)`,
// `exportSkillAsZip(_:)`. Extended in M11 Phase 11.A.2.0 to mirror
// the upstream public surface, with real on-disk persistence via
// `SkillStore` (NOT excluded on Intel — see
// `Models/Agent/SkillStore.swift`).
//
// The legacy `IntelSkillInfo` overloads stay for the chat-side
// callers (FloatingInputCard popup, etc.) that haven't been
// migrated; the new methods use the real `Skill` type from
// `Models/Agent/Skill.swift`. `@MainActor` matches upstream.
@MainActor
final class SkillManager: ObservableObject, @unchecked Sendable {
    static let shared = SkillManager()

    @Published private(set) var skills: [Skill] = []
    @Published private(set) var isRefreshing: Bool = false

    var enabledCount: Int { skills.filter { $0.enabled }.count }

    private init() {
        Task { @MainActor in await refresh() }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        skills = await SkillStore.loadAll()
    }

    @discardableResult
    func create(
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        instructions: String = ""
    ) async -> Skill {
        let skill = Skill(
            name: name,
            description: description,
            version: version,
            author: author,
            category: category,
            instructions: instructions
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func update(_ skill: Skill) async {
        var updated = skill
        updated.updatedAt = Date()
        await SkillStore.save(updated)
        await refresh()
    }

    @discardableResult
    func delete(id: UUID) async -> Bool {
        let result = await SkillStore.delete(id: id)
        if result { await refresh() }
        return result
    }

    func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard var skill = await SkillStore.load(id: id) else { return }
        skill.enabled = enabled
        skill.updatedAt = Date()
        await SkillStore.save(skill)
        await refresh()
    }

    // Import / export paths.
    //
    // The JSON / markdown / zip importers can be implemented on Intel
    // because `SkillStore` + `Skill`'s Codable surface are both
    // present. Only the GitHub-installer path lives in
    // `Services/GitHubSkillService.swift` (excluded), so
    // `importSkillsFromMarkdown(_:)` — which takes pre-fetched skill
    // payloads from the GitHub sheet — is a no-op pass-through here
    // because the sheet is `AppleSiliconOnlyTab` on Intel.

    func importSkill(from data: Data) async throws -> Skill {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var skill = try decoder.decode(Skill.self, from: data)
        // New ID so an import doesn't collide with an existing skill.
        skill = Skill(
            id: UUID(),
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            keywords: skill.keywords,
            enabled: skill.enabled,
            instructions: skill.instructions
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func importSkillFromMarkdown(_ content: String) async throws -> Skill {
        // Minimal Intel implementation — treats the whole markdown blob
        // as the instructions body and derives a default name from the
        // first H1 (or "Imported Skill" if absent). Upstream parses
        // YAML frontmatter for richer metadata; Intel is intentionally
        // simpler since the GitHub-importer (which produces the
        // richest markdown) is amputated.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let h1 = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        let skill = Skill(
            name: h1 ?? "Imported Skill",
            description: "",
            instructions: content
        )
        await SkillStore.save(skill)
        await refresh()
        return skill
    }

    func importSkillsFromMarkdown(_ skills: [Skill]) async -> [Skill] {
        // Used by `GitHubImportSheet.onImport` — on Intel the sheet
        // is `AppleSiliconOnlyTab`, so this path is unreachable from
        // the UI. Kept as a real implementation in case some other
        // code path feeds skills in directly.
        var imported: [Skill] = []
        for skill in skills {
            await SkillStore.save(skill)
            imported.append(skill)
        }
        await refresh()
        return imported
    }

    func importSkillFromZip(_ zipURL: URL) async throws -> Skill {
        // Zip import depends on excluded archiver utilities; surface
        // a clear runtime error rather than silently no-op so the
        // caller's toast shows useful text.
        throw NSError(
            domain: "SkillManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Skill .zip import is unavailable on Intel."]
        )
    }

    func exportSkillAsZip(_ skill: Skill) async throws -> URL {
        // Same constraint as import — zip path requires the excluded
        // archive utilities.
        throw NSError(
            domain: "SkillManager",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Skill .zip export is unavailable on Intel."]
        )
    }

    /// Export a skill as a SKILL.md document following the Agent Skills
    /// spec (https://agentskills.io/specification). Used by
    /// SkillsView's "Export" → "as SKILL.md" affordance. The format
    /// is a YAML frontmatter block followed by the instructions body.
    func exportSkillAsAgentSkills(_ skill: Skill) -> String {
        var lines: [String] = []
        lines.append("---")
        lines.append("name: \(skill.name)")
        if !skill.description.isEmpty {
            lines.append("description: \(skill.description)")
        }
        lines.append("version: \(skill.version)")
        if let author = skill.author, !author.isEmpty {
            lines.append("author: \(author)")
        }
        if let category = skill.category, !category.isEmpty {
            lines.append("category: \(category)")
        }
        if !skill.keywords.isEmpty {
            lines.append("keywords: [\(skill.keywords.joined(separator: ", "))]")
        }
        lines.append("---")
        lines.append("")
        lines.append(skill.instructions)
        return lines.joined(separator: "\n")
    }

    // Legacy chat-side overloads (unchanged surface for
    // FloatingInputCard's slash popup).
    func skill(for id: UUID) -> IntelSkillInfo? { nil }
    func buildFullInstructions(for skill: IntelSkillInfo, agentId: Any? = nil) -> String? { nil }
}

// `SlashCommandsView` (un-body-swapped in M11 Phase 11.A.1) and
// `ManagementBadgeStore` both read `customCommands` to drive the
// Commands sidebar tab + its badge. `SlashCommandStore` (NOT
// excluded on Intel — see `Models/SlashCommand/SlashCommandStore.swift`)
// already handles JSON-on-disk persistence inside the OsaurusPaths
// commands directory, so the Intel conformer can mirror the upstream
// CRUD surface byte-for-byte rather than running an in-memory shim.
//
// `@MainActor` matches the upstream class annotation. Required
// because `SlashCommandStore`'s static CRUD methods are themselves
// `@MainActor`-isolated; calling them from a non-isolated context
// would trigger Swift 6.3's actor-isolated-call diagnostic.
@MainActor
final class SlashCommandRegistry: ObservableObject, @unchecked Sendable {
    static let shared = SlashCommandRegistry()

    @Published var isPopupVisible: Bool = false

    /// User-defined custom commands loaded from disk. Mirrors the
    /// upstream `SlashCommandRegistry.customCommands` published
    /// surface. Refresh() reads from `SlashCommandStore.loadAll()`.
    @Published private(set) var customCommands: [SlashCommand] = []

    private init() {
        refresh()
    }

    /// Re-read every persisted command from disk into `customCommands`.
    /// Called from each CRUD method after the write succeeds.
    func refresh() {
        customCommands = SlashCommandStore.loadAll()
    }

    /// FloatingInputCard reads this every time the user types `/`.
    /// Upstream does prefix-fuzzy across custom + built-in commands.
    /// The built-ins (clear/model/agent/title/help) are NOT amputated on
    /// Intel — `FloatingInputCard.handleBuiltInSlashAction(_:)` already
    /// implements every one of them locally — so surface them here too,
    /// built-ins first then custom (matching upstream's `allCommands`
    /// order in the excluded `Managers/SlashCommandRegistry.swift`),
    /// deduplicated by name so a custom command can't collide with a
    /// built-in of the same name.
    func filtered(query: String) -> [SlashCommand] {
        var seen = Set<String>()
        var all: [SlashCommand] = []
        for cmd in SlashCommand.builtIns + customCommands {
            let key = cmd.name.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            all.append(cmd)
        }
        let q = query.lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().hasPrefix(q) }
    }

    @discardableResult
    func create(
        name: String,
        description: String = "",
        icon: String = "text.bubble",
        template: String,
        pluginId: String? = nil
    ) -> SlashCommand {
        let cmd = SlashCommand(
            name: name,
            description: description,
            icon: icon,
            kind: .template,
            template: template,
            pluginId: pluginId
        )
        SlashCommandStore.save(cmd)
        refresh()
        return cmd
    }

    func update(_ command: SlashCommand) {
        guard !command.isBuiltIn else { return }
        var updated = command
        updated.updatedAt = Date()
        SlashCommandStore.save(updated)
        refresh()
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        let result = SlashCommandStore.delete(id: id)
        if result { refresh() }
        return result
    }
}

// MARK: - Theme Sharing
//
// `ThemeShareOutcome` is defined in the excluded
// `Services/Themes/ThemeShareService.swift` upstream. `ShareThemeSheet`'s
// Intel stub (un-body-swap in M11 Phase 11.A.1's bundle) declares
// `onSuccess: (ThemeShareOutcome) -> Void` in its init signature, so
// the type has to be in scope. Mirror the upstream public surface
// byte-for-byte — the closure is never actually invoked on Intel
// because the share UI immediately routes to `AppleSiliconOnlyTab`,
// but the type is still required at compile time.
public struct ThemeShareOutcome: Sendable {
    public let hash: String
    public let serverURL: URL
    public let deepLinkURL: URL

    public init(hash: String, serverURL: URL, deepLinkURL: URL) {
        self.hash = hash
        self.serverURL = serverURL
        self.deepLinkURL = deepLinkURL
    }
}

// `SlashCommand` is provided by upstream
// `Models/SlashCommand/SlashCommand.swift` (not excluded). The
// Intel duplicate that used to live here has been removed.

enum StreamingStatsHint: Sendable {
    static func encode(tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool = false, stopReason: String? = nil) -> String { "" }
    static func decode(_ delta: String) -> (tokenCount: Int, tokensPerSecond: Double, unclosedReasoning: Bool, stopReason: String?)? { nil }
}

// M13 Schedules restore: made `public` so the un-excluded DispatchRequest /
// ExecutionContext / BackgroundTaskModels (which expose `public let source:
// SessionSource`) compile — the real upstream enum is public too.
public enum SessionSource: String, Codable, CaseIterable, Sendable {
    case chat, plugin, http, schedule, watcher, selfSchedule = "self_schedule"
    /// Conversation imported from another assistant's export (ChatGPT,
    /// Claude, Gemini, Grok, Open WebUI, or generic JSON). Upstream
    /// 311f327c. Continues as a normal chat; the source tag keeps
    /// provenance visible in the sidebar.
    case imported

    var iconName: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .plugin: return "puzzlepiece.extension.fill"
        case .http: return "network"
        case .schedule: return "clock.fill"
        case .watcher: return "eye.fill"
        case .selfSchedule: return "alarm.fill"
        case .imported: return "square.and.arrow.down.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .chat: return "Chat"
        case .plugin: return "Plugin"
        case .http: return "API"
        case .schedule: return "Schedule"
        case .watcher: return "Watcher"
        case .selfSchedule: return "Self-scheduled"
        case .imported: return "Imported"
        }
    }

    func originLabel(pluginDisplayName: String? = nil) -> String? {
        switch self {
        case .chat: return nil
        case .plugin:
            if let name = pluginDisplayName, !name.isEmpty { return "via \(name)" }
            return "via plugin"
        case .http: return "via API"
        case .schedule: return "scheduled"
        case .watcher: return "watcher"
        case .selfSchedule: return "self-scheduled"
        case .imported: return "imported"
        }
    }
}

/// Intel-side mirror of upstream `PluginDisplayNameResolver` (lives in the
/// excluded `SessionSource.swift`). Falls through to the raw plugin id since
/// `PluginManager` is amputated on Intel and we have nothing to look up.
@MainActor
enum PluginDisplayNameResolver {
    static func displayName(for pluginId: String) -> String {
        if pluginId.hasPrefix("sandbox:") {
            return String(pluginId.dropFirst("sandbox:".count))
        }
        return pluginId
    }
}

enum SearchService {
    static func matches(query: String, in text: String) -> Bool {
        guard !query.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(query)
    }
    /// Plugins/Tools search filters use this. Simple substring fuzzy
    /// match (case-insensitive contains) — good enough for the
    /// settings search boxes.
    static func fuzzyMatch(query: String, in target: String) -> Bool {
        guard !query.isEmpty else { return true }
        return target.localizedCaseInsensitiveContains(query)
    }
}
struct LocalAudioSamples: Sendable, Equatable { init() {} }


// `ModelPickerItem`, `ModelPickerSource`, and the
// `Array<ModelPickerItem>.firstChatCapable` extension are now provided
// by upstream `Models/Configuration/ModelPickerItem.swift` (un-excluded
// in Phase 8C-prep-2). The Intel duplicates that used to live here have
// been removed.
//
// Note: `Array<Attachment>.images` is similarly provided by upstream
// `Attachment.swift` (un-excluded in Phase 8C-prep-1).

/// Intel-side ergonomic shim on upstream `ModelPickerItem.Source` so the
/// few `item.source.remoteProviderId == providerId` filter call sites in
/// `ChatView` (and friends) don't need to pattern-match the enum directly.
/// Upstream doesn't expose this because the upstream code uses different
/// matching idioms in those spots; on Intel we kept the simpler form.
extension ModelPickerItem.Source {
    var remoteProviderId: UUID? {
        if case .remote(_, let providerId) = self { return providerId }
        return nil
    }
}

// MARK: - Additional stubs

struct DiscoveredAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var relayToken: String? { nil }
    var providerId: UUID? { nil }
    var displayName: String { "" }
    var name: String { "" }
    var agentDescription: String { "" }
    var host: String? { nil }
    var port: Int? { nil }
    var address: String? { nil }
    var kind: String { "" }
    var providerType: String { "" }
}

struct PairedRelayAgent: Identifiable, Sendable {
    public let id = UUID()
    var token: String? { nil }
    var remoteAgentId: UUID? { nil }
    var remoteAgentAddress: String { "" }
    var providerId: UUID { UUID() }
    var address: String { "" }
    var name: String { "" }
    var host: String { "" }
    var port: Int? { nil }
    var kind: String { "relay" }
    var providerType: String { "" }
}

final class ContextBudgetManager: @unchecked Sendable {
    static let shared = ContextBudgetManager()

    /// Cheap GPT-style estimator. Mirrors the upstream's "≈4 chars / token"
    /// approximation that ChatView documents at L590. Off-by-a-few is fine
    /// for the chip — it's a budget tracker, not a billing meter.
    static func estimateTokens(for text: String) -> Int { max(1, text.count / 4) }

    /// Sum the content + thinking footprint of an arbitrary turn list. The
    /// previous Intel stub returned 0 here, which meant the FloatingInputCard
    /// Context Budget popover only showed the typing tokens — every other
    /// row stayed at zero. Now the popover reflects the live conversation
    /// the way it does on Apple Silicon.
    static func estimateTokens(for turns: [ChatTurn]) -> Int {
        turns.reduce(0) { acc, turn in
            acc + estimateTokens(for: turn.content) + estimateTokens(for: turn.thinking)
        }
    }

    /// The "output" rail tracks just the active streaming turn. ChatView
    /// uses this to peel it off the total conversation tokens so the
    /// popover can show "Conversation" + "Output" as distinct lines.
    static func estimateOutputTokens(for turns: [ChatTurn]) -> Int {
        guard let last = turns.last, last.role == .assistant else { return 0 }
        return estimateTokens(for: last.content) + estimateTokens(for: last.thinking)
    }

    /// Estimate the wire-token cost of a tool schema (name + description +
    /// serialized JSON-Schema parameters). Shared by `composeChatContext`
    /// (the real send) and the restored-session budget preview so both agree.
    static func estimateToolTokens(_ tools: [IntelTool]) -> Int {
        var total = 0
        for t in tools {
            total += estimateTokens(for: t.function.name)
            total += estimateTokens(for: t.function.description ?? "")
            if let params = t.function.parameters,
                let data = try? JSONSerialization.data(withJSONObject: params.anyValue),
                let json = String(data: data, encoding: .utf8)
            {
                total += estimateTokens(for: json)
            }
        }
        return total
    }

    /// Overload for callers whose value is statically typed `Any?` — notably
    /// `ChatView.refreshMemoryTokens()`, which calls this with
    /// `MemoryContextAssembler.assembleContext(...)`'s return value. Swift
    /// binds overloads by the argument's STATIC type, so with this
    /// hard-returning `0` (as it used to), the `String` overload above was
    /// unreachable for that value no matter what `assembleContext` returned
    /// or how big it was: the context-budget popover's memory row was
    /// wired to always read 0. Unwrap the concrete case that call site
    /// actually produces and delegate to the real estimator.
    static func estimateTokens(for item: Any?) -> Int {
        if let text = item as? String { return estimateTokens(for: text) }
        return 0
    }
}

// M12 Gap 3: the real `ToolEnvelope` (Tools/ToolEnvelope.swift) + the legacy
// `ToolErrorEnvelope` (Tools/ToolErrorEnvelope.swift) are un-excluded so the
// restored file/shell tools return their real structured result/error JSON.
// The hollow mirror that used to live here is therefore removed.

// M12 Gap 3: `shell_run` (FolderTools.swift) broadcasts its live output to the
// chat terminal viewer through a `LiveExecSink`. The real sink
// (Services/Sandbox/LiveExecSink.swift) implements `Containerization.Writer`
// and is therefore amputated on Intel. `LiveExecRegistry` itself is clean
// (Combine + Foundation, NOT excluded), so we keep the registration path live
// and only stub the sink: the command still runs and its output is collected
// for the model via `ShellRunOutputCollector` — only the optional live
// mid-run UI streaming is inert (the chat shows the final result instead).
final class LiveExecSink: @unchecked Sendable {
    enum TerminationReason: Sendable, Equatable { case none, user }
    init() {}
    var terminationReason: TerminationReason { .none }
    var outputPublisher: AnyPublisher<Data, Never> { Empty().eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<LiveExecRegistry.LiveExecStatus, Never> {
        Empty().eraseToAnyPublisher()
    }
    var currentStatus: LiveExecRegistry.LiveExecStatus { .running }
    func bufferedSnapshot() async -> Data { Data() }
    func write(_ data: Data) throws {}
    func markExited(code: Int32) {}
    func requestTerminate() {}
    func close() throws {}
}

// M12 Gap 3: the real `diagnosticWarnings` lives in the excluded
// `Tools/BuiltinSandboxTools.swift`. `shell_run` calls it to flag suspicious
// empty output; on Intel we return no warnings (the command result itself is
// unaffected).
func diagnosticWarnings(command: String, exitCode: Int32, stdout: String, stderr: String) -> [String] { [] }

final class SessionToolStateStore: @unchecked Sendable {
    static let shared = SessionToolStateStore()
    func invalidate(_ key: Any) async {}
    func invalidateAll() async {}
    func invalidateIfFingerprintChanged(_ key: Any, liveFingerprint: Any) async {}
    func get(_ key: Any) async -> SessionToolState? { nil }
    func setInitial(_ key: Any, preflight: Any?, alwaysLoadedNames: Any?, fingerprint: String) async {}
    func recordSend(sessionId: Any, cacheHint: Any?, trace: Any?) async {}
    func appendLoadedTools(_ key: Any, names: [String], fallbackPreflight: Any?, fallbackAlwaysLoadedNames: Any?) async {}
}

final class TTSService: ObservableObject, @unchecked Sendable {
    func toggleSpeak(text: String, messageId: UUID, voiceOverride: Any? = nil) {}
    func stop() {}
    var playingMessageId: UUID? { nil }
    var activeSpeakCallId: String? { nil }
    static let shared = TTSService()
    func refreshModelState() {}
    var selectedVoice: Any? { nil }
    var isSpeaking: Bool { false }
    var selectedModel: Any? { nil }
    var isModelReady: Bool { false }
}

struct MockChatData: Sendable {
    init() {}
    static var isEnabled: Bool { false }
    static let shared = MockChatData()
    static func mockTurnsForPerformanceTest(count: Int = 10) -> [ChatTurn] { [] }
}

struct ServiceToolInvocation: Sendable {
    init() {}
    var toolCallId: String? { nil }
    var toolName: String { "" }
    var jsonArguments: String { "" }
    var geminiThoughtSignature: String? { nil }
}

struct ServiceToolInvocations: Error, Sendable {
    let invocations: [ServiceToolInvocation]
}

enum PromptQueueItem: Identifiable, Sendable {
    case secret(SecretPromptState)
    case clarify(ClarifyPromptState)

    var id: String {
        switch self {
        case .secret: return "secret"
        case .clarify: return "clarify"
        }
    }
}

final class PromptQueue: ObservableObject, @unchecked Sendable {
    var current: PromptQueueItem? { nil }
    func enqueue(_ item: PromptQueueItem) {}
    func drainAll() {}
    func advance() {}
}

struct ClarifyPayload: Sendable, Equatable {
    let question: String = ""
    let options: [String] = []
    let allowMultiple: Bool = false
}

final class BlockMemoizer: @unchecked Sendable {
    init() {}
    static let shared = BlockMemoizer()
    func blocks(from turns: [ChatTurn], streamingTurnId: UUID? = nil, agentName: String = "", version: Int = 0, thinkingEnabled: Bool = false) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        // Track which "side" (user vs assistant) the previous rendered turn
        // belonged to, so a header is emitted only when the side flips.
        // Consecutive assistant + tool turns (a tool round) share one header.
        var prevSideIsUser: Bool?
        for turn in turns {
            // M12 Gap 3: `.tool`-role turns exist ONLY to carry the tool result
            // back to the API on the continuation request. Their content is the
            // raw result envelope and must NOT render as a chat bubble — it's
            // already shown inside the assistant turn's tool-call card (via
            // `toolResults`). The simplified Intel builder used to fall through
            // to the assistant-paragraph branch and dump that JSON into the
            // stream (Renée 2026-06-03). Skip them.
            if turn.role == .tool { continue }

            let isUser = turn.role == .user

            // Header only when the conversation side flips (or at the very top).
            if prevSideIsUser != isUser {
                blocks.append(ContentBlock(
                    id: "header-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .header(role: turn.role, agentName: agentName, isFirstInGroup: blocks.isEmpty)
                ))
            }
            prevSideIsUser = isUser

            // Thinking
            if !turn.thinking.isEmpty {
                blocks.append(ContentBlock(
                    id: "thinking-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .thinking(index: blocks.count, text: turn.thinking, isStreaming: turn.id == streamingTurnId)
                ))
            }

            // User message
            if isUser && !turn.content.isEmpty {
                blocks.append(ContentBlock(
                    id: "user-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .userMessage(text: turn.content, attachments: turn.attachments)
                ))
            }

            // Assistant message (paragraph) — the pre-tool framing ("Sure
            // thing! Let me peek…") streams before the tool call, so render it
            // BEFORE the card.
            if !isUser && !turn.content.isEmpty {
                blocks.append(ContentBlock(
                    id: "assistant-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .paragraph(
                        index: blocks.count,
                        text: turn.content,
                        isStreaming: turn.id == streamingTurnId,
                        role: .assistant
                    )
                ))
            }

            // In-flight tool call: render the card the MOMENT the model emits
            // the call (pendingToolName set by the engine's StreamingToolHint),
            // BEFORE/while the tool executes — so the user sees "calling X …"
            // with the query, and the result fills in on completion. Cleared by
            // ChatView on `decodeDone`, when the completed `toolCalls` block
            // below takes over (the two are mutually exclusive per call).
            if !isUser, let pendingName = turn.pendingToolName, !pendingName.isEmpty {
                blocks.append(ContentBlock(
                    id: "pendingtool-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .pendingToolCall(
                        toolName: pendingName,
                        argPreview: turn.pendingToolArgPreview,
                        argSize: turn.pendingToolArgSize
                    )
                ))
            }

            // Tool-call cards (M12 Gap 3): rendered via NativeToolCallGroupView.
            // Each call pairs with its result from `turn.toolResults`, so the
            // result shows inside the (expandable) card — not as a chat bubble.
            if !isUser, let toolCalls = turn.toolCalls, !toolCalls.isEmpty {
                let items = toolCalls.map {
                    ToolCallItem(call: $0, result: turn.toolResults[$0.id])
                }
                blocks.append(ContentBlock(
                    id: "toolgroup-\(turn.id.uuidString)",
                    turnId: turn.id,
                    kind: .toolCallGroup(calls: items)
                ))
            }
        }
        return blocks
    }
    var groupHeaderMap: [UUID: UUID] { [:] }
    func memoized<T>(forKey key: String, build: () -> T) -> T { build() }
    func clear() {}
}

// M12 Gap 3: real sentinel protocol between `CloudChatEngine` (which runs the
// DeepSeek tool loop) and `ChatView`'s stream-delta decoder. The engine yields
// these tagged strings interleaved with normal content; ChatView routes them
// (decodeDone → tool-call card + result turn; decode → pending tool name).
// Prefixes use an ESC control char + bracket tag so they can't collide with
// model-authored content. The hollow stub these replace meant tool calls were
// never decoded even if the engine had emitted them.
struct StreamingToolHint: Sendable {
    private static let donePrefix = "\u{1B}[[OSX_TOOL_DONE]]"
    private static let namePrefix = "\u{1B}[[OSX_TOOL_NAME]]"
    private static let argsPrefix = "\u{1B}[[OSX_TOOL_ARGS]]"

    static func encode(_ toolName: String) -> String { namePrefix + toolName }
    static func encodeArgs(_ fragment: String) -> String { argsPrefix + fragment }
    static func encodeDone(callId: String, name: String, arguments: String, result: String) -> String {
        let dict: [String: String] = [
            "callId": callId, "name": name, "arguments": arguments, "result": result,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return donePrefix + (String(data: data, encoding: .utf8) ?? "")
    }
    static func decodeDone(_ delta: String) -> ToolCallDone? {
        guard delta.hasPrefix(donePrefix) else { return nil }
        let json = String(delta.dropFirst(donePrefix.count))
        guard let data = json.data(using: .utf8),
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return ToolCallDone(
            callId: d["callId"] ?? "",
            name: d["name"] ?? "",
            arguments: d["arguments"] ?? "",
            result: d["result"] ?? ""
        )
    }
    static func isSentinel(_ delta: String) -> Bool {
        delta.hasPrefix(donePrefix) || delta.hasPrefix(namePrefix) || delta.hasPrefix(argsPrefix)
    }
    static func decode(_ delta: String) -> String? {
        delta.hasPrefix(namePrefix) ? String(delta.dropFirst(namePrefix.count)) : nil
    }
    static func decodeArgs(_ delta: String) -> String? {
        delta.hasPrefix(argsPrefix) ? String(delta.dropFirst(argsPrefix.count)) : nil
    }
}

struct ToolCallDone: Sendable, Equatable {
    let callId: String
    let name: String
    let arguments: String
    let result: String
}

@MainActor
final class StreamingDeltaProcessor: @unchecked Sendable {
    private let turn: ChatTurn
    private let onChange: @MainActor @Sendable () -> Void

    init(turn: ChatTurn, onChange: @escaping @MainActor @Sendable () -> Void = {}) {
        self.turn = turn
        self.onChange = onChange
    }

    func finalize() {
        onChange()
    }

    func receiveReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        turn.appendThinking(text)
        // Refresh the UI per chunk so the Think panel streams LIVE, exactly
        // like content (receiveDelta). Without this the thinking accumulated
        // silently and only appeared when finalize() fired at end-of-stream —
        // so a long (8k+ char) thought looked like a multi-second blank stall.
        // Painting cadence is paced by the ~12/sec runloop yield in
        // processStreamDeltas, same as content deltas.
        onChange()
    }

    func receiveDelta(_ delta: Any) {
        guard let text = delta as? String, !text.isEmpty else { return }
        turn.appendContent(text)
        onChange()
    }
}
/// Intel mirror of the upstream `StreamingReasoningHint` (lives in the
/// excluded `Services/Inference/ModelService.swift` alongside MLX). The
/// previous Intel stub returned `nil` from `decode(_:)`, which meant
/// `CloudChatEngine`'s reasoning-content chunks (DeepSeek V4 Pro's
/// `Max` mode emits a separate `reasoning_content` SSE field) couldn't
/// be routed to `ChatTurn.thinking` and silently disappeared — so users
/// got the answer but no Think panel.
///
/// Same `\u{FFFE}reasoning:` sentinel prefix as upstream so the
/// `ChatView` decode site (`StreamingReasoningHint.decode(delta)` at
/// L1721) works without an architecture-specific branch.
enum StreamingReasoningHint: Sendable {
    private static let reasoningPrefix = "\u{FFFE}reasoning:"
    static func encode(_ text: String) -> String { reasoningPrefix + text }
    static func decode(_ delta: String) -> String? {
        guard delta.hasPrefix(reasoningPrefix) else { return nil }
        return String(delta.dropFirst(reasoningPrefix.count))
    }
}

final class SystemPromptComposer: @unchecked Sendable {
    static let shared = SystemPromptComposer()
    static func composePreviewContext(agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil) -> ComposedContext { ComposedContext() }
    // M12 Gap 1 follow-up: the real `SystemPromptComposer` is excluded on
    // Intel (it pulls in preflight / memory / tool-resolution machinery that
    // depends on amputated subsystems). Returning an empty `ComposedContext`
    // meant `context.prompt` was always "" — so the chat ignored the selected
    // agent entirely (Renée 2026-06-03). We can't run the full pipeline, but
    // we CAN honor the one thing that matters here: the agent's effective
    // system prompt (custom prompt for custom agents, global config prompt
    // for Default). Memory/tools stay inert, matching the amputated build.
    static func composeChatContext(agentId: Any? = nil, executionMode: Any? = nil, model: String? = nil, query: String? = nil, messages: [Any] = [], toolsDisabled: Bool = false, cachedPreflight: Any? = nil, additionalToolNames: [String] = [], frozenAlwaysLoadedNames: Any? = nil, trace: Any? = nil, projectId: UUID? = nil) async -> ComposedContext {
        let id = (agentId as? UUID) ?? Agent.defaultId
        let (basePrompt, folder, toolMode, enabledToolNames, folderToolNames) = await MainActor.run {
            (
                AgentManager.shared.effectiveSystemPrompt(for: id),
                FolderContextService.shared.currentContext,
                AgentManager.shared.effectiveToolSelectionMode(for: id),
                AgentManager.shared.effectiveEnabledToolNames(for: id),
                Set(FolderToolManager.shared.folderToolNames)
            )
        }
        // M12 Gap 3: when a working folder is mounted, append the real
        // "## Working Directory" framing (SystemPromptTemplates.folderContext —
        // NOT excluded). Without it the model just had bare tool specs and no
        // context, so DeepSeek hallucinated tool output as plain text instead
        // of emitting a real call (Renée 2026-06-03). The section carries the
        // path, project type, root contents, git status, the path rule, and
        // the per-tool dispatch guide that primes actual tool calls.
        let folderSection = SystemPromptTemplates.folderContext(from: folder)
        // M12 Gap 3: DeepSeek V4 Flash is an inconsistent tool-caller — with
        // only the (descriptive) folder guide it sometimes role-plays tool use
        // in prose and fabricates listings/contents/`ls` output instead of
        // emitting real calls (Renée 2026-06-03). The base system-instruction
        // tool directives that anchor this on Apple Silicon live in excluded
        // files, so we add a firm, recency-positioned directive here.
        let toolDirective: String
        if folder != nil {
            toolDirective = """

                ## Tool Use (MANDATORY)
                You have REAL tools that execute on the user's actual filesystem. \
                To list, read, search, write, or edit files — or run shell commands — \
                you MUST emit the matching tool call (`file_tree`, `file_read`, \
                `file_search`, `file_write`, `file_edit`, `shell_run`) and use its \
                returned result. The "Root contents" above is only a partial hint; \
                for any real answer, CALL the tool. NEVER fabricate, guess, or \
                simulate file names, file contents, or command output — if you have \
                not called the tool this turn, you do not know the answer. Do not \
                describe running a command in prose; actually call the tool.
                """
        } else {
            toolDirective = ""
        }
        var prompt = basePrompt + folderSection + toolDirective
        // Track each slice of the prompt so the budget popover can show them as
        // distinct rails (Persona / Grounding / Agent Loop / …).
        var sections: [PromptSection] = []
        if !basePrompt.isEmpty {
            sections.append(PromptSection(id: "persona", label: "Persona", text: basePrompt, tint: .purple))
        }
        if !folderSection.isEmpty {
            sections.append(PromptSection(id: "grounding", label: "Grounding", text: folderSection, tint: .teal))
        }
        if !toolDirective.isEmpty {
            sections.append(PromptSection(id: "agentLoop", label: "Agent Loop", text: toolDirective, tint: .indigo))
        }
        // Surface the registered tools, honoring the agent's capability picker
        // (M12 follow-up): in Manual mode, restrict to the agent's enabled
        // allowlist; in Auto mode (or un-seeded), send everything registered.
        let tools: [Tool]
        if toolsDisabled {
            tools = []
        } else {
            let allSpecs = ToolRegistry.shared.openAISpecs()
            if toolMode == .manual, let enabled = enabledToolNames {
                // Folder/runtime tools (file_read, file_write, file_edit,
                // file_search, file_tree, shell_run, git_*) are auto-mounted with
                // the working directory and must BYPASS the manual capability
                // allowlist — mirrors upstream, where runtime-managed tools form the
                // always-loaded baseline and the manual picker only ADDS discretionary
                // tools on top. Without this, selecting a folder gave a Manual-mode
                // agent the "## Working Directory" prompt but none of the actual
                // file/shell tool specs, so it couldn't call them (Renée, native
                // Ventura, 2026-06-12).
                let allowed = Set(enabled).union(folderToolNames)
                tools = allSpecs.filter { allowed.contains($0.function.name) }
            } else {
                tools = allSpecs
            }
        }
        // Append plugin-declared `instructions` for any plugin whose tools are
        // active this turn, so a plugin can shape how the model wields it.
        if !tools.isEmpty {
            let activeNames = Set(tools.map { $0.function.name })
            let pluginInstructions = await MainActor.run {
                PluginManager.shared.instructions(forActiveToolNames: activeNames)
            }
            if !pluginInstructions.isEmpty {
                let block = "\n\n## Plugin Instructions\n" + pluginInstructions.joined(separator: "\n\n")
                prompt += block
                sections.append(
                    PromptSection(
                        id: "pluginInstructions", label: "Plugin Instructions", text: block, tint: .cyan)
                )
            }
        }
        // Estimate the tool-schema token cost so the budget popover shows a real
        // "Tools" rail instead of 0.
        let toolTokens = ContextBudgetManager.estimateToolTokens(tools)

        // Recall: assemble the layered memory block (identity → pinned →
        // episodes → transcript fallback) that `injectMemoryPrefix` will splice
        // in just before the user's message.
        var memorySection: String? = nil
        let memCfg = MemoryConfigurationStore.load()
        if memCfg.enabled, let q = query?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            // Search across all agents (agentId: nil) so recall works regardless
            // of how the transcript/episode agent id was stamped; per-agent
            // scoping is a later refinement.
            let days = memCfg.episodeRetentionDays > 0 ? memCfg.episodeRetentionDays : 3650
            memorySection = await MemorySearchService.shared.recall(
                query: q, agentId: nil, days: days, budgetTokens: memCfg.memoryBudgetTokens)
        }

        // Project instructions: shared free-form context for every chat in a
        // project. Rides the SAME cache-safe inject-prefix path as recalled
        // memory (spliced in by `injectMemoryPrefix` just before the last
        // user turn) rather than the stable `prompt` above, so this stays a
        // single injection point — Intel Projects have no per-turn-variable
        // content, but reusing the existing plumbing avoids a second path
        // doing the same job.
        if let projectId,
            let instructions = await MainActor.run(body: {
                ProjectManager.shared.project(for: projectId)?.instructions
            })?.trimmingCharacters(in: .whitespacesAndNewlines),
            !instructions.isEmpty
        {
            let block = "## Project Instructions\n" + instructions
            memorySection = [block, memorySection].compactMap { $0 }.joined(separator: "\n\n")
        }

        return ComposedContext(
            prompt: prompt, toolTokens: toolTokens, tools: tools,
            memorySection: memorySection, promptSections: sections)
    }

    /// Splice the memory block in as its own system message immediately *before*
    /// the final user turn — so the long, stable system prefix stays byte-identical
    /// (keeps DeepSeek's prompt cache warm) while memory sits next to the query.
    static func injectMemoryPrefix(_ section: String?, into messages: inout [ChatMessage]) {
        guard let section, !section.isEmpty else { return }
        let mem = ChatMessage(role: "system", content: section)
        if let lastUser = messages.lastIndex(where: { $0.role == "user" }) {
            messages.insert(mem, at: lastUser)
        } else {
            messages.append(mem)
        }
    }
}

struct PromptManifest: Sendable { init() {} }

// M12 Gap 3: OpenAI-compatible tool spec carried in `ChatCompletionRequest.tools`.
// `OsaurusTool.asOpenAITool()` builds
// `Tool(type:, function: ToolFunction(name:description:parameters:))`, so the
// function MUST carry a JSON-Schema `parameters` object — that's what the model
// reads to call the tool with the right argument shape. The earlier mirror
// dropped `parameters` (and split into two incompatible `ToolFunction` types),
// which would have shipped schema-less tools the model couldn't invoke.
struct ToolFunction: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: JSONValue?
    init(name: String, description: String? = nil, parameters: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

struct IntelTool: Codable, Sendable {
    let type: String
    let function: ToolFunction
    init(type: String = "function", function: ToolFunction) {
        self.type = type
        self.function = function
    }
}

typealias Tool = IntelTool

enum ToolChoiceOption: Codable, Sendable {
    case auto
    case none
    case required
    case function(String)
}

/// A named, individually-measurable slice of the Intel system prompt, so the
/// context-budget popover can show Persona / Grounding / Agent Loop / Plugin
/// Instructions as distinct rails — matching the granularity of upstream's
/// PromptManifest sections (minus the local-model-only ones the fork amputates).
struct PromptSection: Sendable {
    let id: String
    let label: String
    let text: String
    let tint: ContextBreakdown.Tint
}

struct ComposedContext: @unchecked Sendable {
    let prompt: String
    let manifest: PromptManifest
    let toolTokens: Int
    var tools: [IntelTool]
    var preflight: Any?
    var alwaysLoadedNames: Any?
    var preflightItems: [Any]
    var memorySection: String?
    var cacheHint: Any?
    /// Named slices of `prompt`, in order, for the budget breakdown. Empty for
    /// the lightweight restored-session preview (which falls back to a single
    /// "System Prompt" rail).
    var promptSections: [PromptSection]
    init(prompt: String = "", manifest: PromptManifest = PromptManifest(), toolTokens: Int = 0, tools: [IntelTool] = [], preflight: Any? = nil, alwaysLoadedNames: Any? = nil, preflightItems: [Any] = [], memorySection: String? = nil, cacheHint: Any? = nil, promptSections: [PromptSection] = []) {
        self.prompt = prompt
        self.manifest = manifest
        self.toolTokens = toolTokens
        self.tools = tools
        self.preflight = preflight
        self.alwaysLoadedNames = alwaysLoadedNames
        self.preflightItems = preflightItems
        self.memorySection = memorySection
        self.cacheHint = cacheHint
        self.promptSections = promptSections
    }
}
/// Auto-disable hints flowed from the context budget composer to the
/// FloatingInputCard's context-popover. On Intel none of this fires
/// (the composer's local-model budgeting paths are amputated) but
/// the upstream popover code reads the props unconditionally — Bool
/// defaults make the relevant rows collapse correctly.
struct ContextDisableInfo: Sendable {
    var modelId: String? = nil
    var contextLength: Int? = nil
    var disabledMemory: Bool = false
    var disabledTools: Bool = false

    init(
        modelId: String? = nil,
        contextLength: Int? = nil,
        disabledMemory: Bool = false,
        disabledTools: Bool = false
    ) {
        self.modelId = modelId
        self.contextLength = contextLength
        self.disabledMemory = disabledMemory
        self.disabledTools = disabledTools
    }
}

struct ContextBreakdown: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        var tokens: Int
        let tint: ContextBreakdown.Tint
        init(id: String, label: String, tokens: Int, tint: ContextBreakdown.Tint = .gray) {
            self.id = id; self.label = label; self.tokens = tokens; self.tint = tint
        }
    }
    enum Tint: String, Sendable { case purple, blue, orange, green, gray, cyan, teal, indigo }
    var context: [Entry] = []
    var messages: [Entry] = []
    var disable: ContextDisableInfo? = nil
    var total: Int { context.reduce(0) { $0 + $1.tokens } + messages.reduce(0) { $0 + $1.tokens } }
    var allEntries: [Entry] { context + messages }
    static let zero = ContextBreakdown()

    init(context: [Entry] = [], messages: [Entry] = [], disable: ContextDisableInfo? = nil) {
        self.context = context; self.messages = messages; self.disable = disable
    }

    /// Upsert helper used by `FloatingInputCard.displayContextBreakdown` so
    /// the typing-tokens entry can be written back into the breakdown
    /// without dropping the existing context / message rows.
    mutating func setTokens(
        for id: String,
        in keyPath: WritableKeyPath<ContextBreakdown, [Entry]>,
        tokens: Int,
        label: String,
        tint: Tint
    ) {
        if let idx = self[keyPath: keyPath].firstIndex(where: { $0.id == id }) {
            self[keyPath: keyPath][idx].tokens = tokens
        } else {
            self[keyPath: keyPath].append(
                Entry(id: id, label: label, tokens: tokens, tint: tint)
            )
        }
    }

    static func from(
        context composed: ComposedContext,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        // The Intel `ComposedContext` DOES carry the real system prompt and a
        // tool-token estimate (see `SystemPromptComposer.composeChatContext`),
        // so surface them as proper rails. `context` = the static prefix
        // (System Prompt + Tools); `messages` = the dynamic part (Conversation
        // + Input + Output), rendered below a divider — matching upstream's
        // popover layout. Empty rails are skipped to keep it compact.
        var bd = ContextBreakdown()

        // Per-section prompt rails (Persona / Grounding / Agent Loop / Plugin
        // Instructions) when the composer provided them; otherwise fall back to
        // a single "System Prompt" rail (e.g. the restored-session preview,
        // which only has the agent persona).
        if !composed.promptSections.isEmpty {
            for section in composed.promptSections {
                let t = ContextBudgetManager.estimateTokens(for: section.text)
                if t > 0 {
                    bd.context.append(Entry(id: section.id, label: section.label, tokens: t, tint: section.tint))
                }
            }
        } else {
            let promptTokens =
                composed.prompt.isEmpty ? 0 : ContextBudgetManager.estimateTokens(for: composed.prompt)
            if promptTokens > 0 {
                bd.context.append(Entry(id: "persona", label: "System Prompt", tokens: promptTokens, tint: .purple))
            }
        }
        // Prefer the precomputed count; fall back to estimating from the tool
        // specs so the restored-session preview (which doesn't precompute) still
        // shows a real Tools rail.
        let toolTokens =
            composed.toolTokens > 0
            ? composed.toolTokens : ContextBudgetManager.estimateToolTokens(composed.tools)
        if toolTokens > 0 {
            bd.context.append(Entry(id: "tools", label: "Tools", tokens: toolTokens, tint: .orange))
        }

        if conversationTokens > 0 {
            bd.messages.append(Entry(id: "conversation", label: "Conversation", tokens: conversationTokens, tint: .blue))
        }
        if inputTokens > 0 {
            bd.messages.append(Entry(id: "input", label: "Input", tokens: inputTokens, tint: .cyan))
        }
        if outputTokens > 0 {
            bd.messages.append(Entry(id: "output", label: "Output", tokens: outputTokens, tint: .green))
        }
        return bd
    }

    static func from(
        manifest: PromptManifest,
        toolTokens: Int = 0,
        memoryTokens: Int = 0,
        conversationTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0
    ) -> ContextBreakdown {
        ContextBreakdown()
    }

    static func tint(for sectionId: String) -> Tint { .gray }
}

final class ContextBudgetTracker: @unchecked Sendable {
    init() {}
    func clear() {}
    var estimatedTokens: Int { 0 }
    func activeBreakdown(isActive: Bool = false, outputTurn: ChatTurn? = nil) -> ContextBreakdown? { nil }
    func snapshot(context: ComposedContext) {}
    func updateConversation(tokens: Int, finishedOutputTurn: ChatTurn?) {}
}

final class LiveVoiceAudioInputRegistry: @unchecked Sendable {
    static let shared = LiveVoiceAudioInputRegistry()
    func samples(for id: UUID) -> LocalAudioSamples? { nil }
    /// FloatingInputCard's live-voice preencode session calls this when
    /// either the session ends or the user discards the recording. Intel
    /// has no live-voice path (the whole MLX-backed preencode pipeline is
    /// amputated), so the bookkeeping is a no-op.
    func remove(for id: UUID) {}
    /// FloatingInputCard's send path tags the wav attachment with the
    /// matching live snapshot. Stored snapshots are read back later by
    /// the (Intel-absent) preencode pipeline. No-op on Intel.
    func store(snapshot: LiveVoiceAudioSnapshot, for id: UUID) {}
}

// NOTE (Intel memory port): the minimal `MemoryDatabase` stub that used to live
// here was removed — the real `Storage/MemoryDatabase.swift` is now compiled on
// Intel (it's pure OsaurusSQLCipher, no MLX/VecturaKit) and is a superset of the
// stub's API, so compiled callers (ChatView, MemoryView, AgentsView) bind to it
// directly.

// `IdentityView` (un-body-swapped in M11 Phase 11.A.1) reads
// `@EnvironmentObject private var server: ServerController`, which
// requires `ObservableObject` conformance. The upstream class at
// `Networking/ServerController.swift` (excluded on Intel) is an
// `ObservableObject` with `@Published` properties; we mirror just
// the protocol conformance here so SwiftUI's environment-object
// plumbing type-checks. The HTTP server itself is wired through
// `OsaurusServer` directly in `AppDelegate`, not through this
// controller surface — `restartServer()` below bridges to it.
//
// Settings-tab revival (2026-09-04, Renée): `configuration` used to be
// a hardcoded `Any? { nil }` with `port` pinned to a literal 1338 —
// there was no way for the Server → Settings tab to change or persist
// the listening port at all. It now holds the real, persisted
// `ServerConfiguration` (same file `AppDelegate` reads at launch), so
// `ServerSettingsTabContent` can edit port / CORS / proxy / body-size
// caps and have `restartServer()` actually apply them.
@MainActor
final class ServerController: ObservableObject, @unchecked Sendable {
    static let shared = ServerController()

    static func signalGenerationStart() {}
    static func signalGenerationEnd() {}

    @Published var configuration: ServerConfiguration = ServerConfigurationStore.load() ?? .default

    var port: Int { configuration.port }
    var isRunning: Bool { true }

    /// ServerView (un-body-swapped in M11 Phase 11.B.1) reads these for
    /// the connection URL + status badge. The Intel HTTP server
    /// (`OsaurusServer`) is loopback-only and always up while the app
    /// runs, so health is `.running` and the address is loopback.
    var localNetworkAddress: String { "127.0.0.1" }
    var serverHealth: ServerHealth { .running }

    /// ServerView's start button. The Intel `OsaurusServer` is started
    /// from `AppDelegate` at launch and stays up, so this is a no-op
    /// (the button only shows when health is `.stopped`, which never
    /// happens on Intel).
    func startServer() async {}

    /// Persists `configuration` and asks `AppDelegate` to stop + restart
    /// the live `OsaurusServer` in place with the new port / CORS /
    /// body-size caps. Also the same path `IdentityView` calls after an
    /// agent's address rotates/revokes — access-key validation reads the
    /// live `APIKeyManager` on each request, so the restart there is
    /// only to be safe, not because keys are cached.
    func restartServer() async {
        await AppDelegate.shared?.applyServerConfiguration(configuration)
    }
}

extension ChatMessage {
    init(role: String, text: String, imageData: [Data]) {
        self.init(role: role, content: text.isEmpty ? nil : text)
    }

    init(
        role: String,
        text: String,
        imageData: [Data],
        audios: [(data: Data, format: String)],
        localAudioSamples: [LocalAudioSamples?] = [],
        videos: [(data: Data, mimeSubtype: String)]
    ) {
        self.init(role: role, content: text.isEmpty ? nil : text)
    }
}



struct RemoteProviderServiceError: Error, Sendable {}


// Notification names
extension NSNotification.Name {
    static let remoteProviderModelsChanged = NSNotification.Name("remoteProviderModelsChanged")
    static let localModelsChanged = NSNotification.Name("localModelsChanged")
    static let chatOverlayActivated = NSNotification.Name("chatOverlayActivated")
    static let chatToolbarSelectDiscoveredAgent = NSNotification.Name("chatToolbarSelectDiscoveredAgent")
    static let chatToolbarSelectRelayAgent = NSNotification.Name("chatToolbarSelectRelayAgent")
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = NSNotification.Name("chatToolbarOpenAgentPicker")
    static let vadStartNewSession = NSNotification.Name("vadStartNewSession")
    static let chatViewClosed = NSNotification.Name("chatViewClosed")
    static let toolsListChanged = NSNotification.Name("toolsListChanged")
    static let ttsPlaybackStateChanged = NSNotification.Name("osaurus.ttsPlaybackStateChanged")
}
#endif

#if OSAURUS_INTEL

// MARK: - ThreadCache Intel conformer
// Mirrors the excluded Managers/ThreadCache.swift. No-op caching:
// always cache-miss → forces re-parse per render. Correctness preserved.
//
// ParsedMarkdown is replicated here because the upstream type lives inside
// the excluded ThreadCache.swift. MessageBlock + ContentSegment stubs are
// minimal — real definitions live in MarkdownMessageView.swift (un-body-
// swapped in Phase 4-0c, simultaneous with this commit).

import AppKit

struct ParsedMarkdown {
    let blocks: [MessageBlock]
    let segments: [ContentSegment]
}

final class ThreadCache: @unchecked Sendable {
    static let shared = ThreadCache()
    private init() {}

    func height(for key: String) -> CGFloat? { nil }
    func setHeight(_ height: CGFloat, for key: String) {}

    func markdown(for text: String) -> ParsedMarkdown? { nil }
    func setMarkdown(blocks: [MessageBlock], segments: [ContentSegment], for text: String) {}

    func image(for urlString: String) -> NSImage? { nil }
    func setImage(_ image: NSImage, for urlString: String) {}

    func clear() {}

    static func imageCacheKey(for urlString: String) -> NSString {
        urlString as NSString
    }
}

#endif
