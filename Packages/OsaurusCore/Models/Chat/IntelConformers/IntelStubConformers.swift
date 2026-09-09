//
//  IntelStubConformers.swift
//  OsaurusCore
//
//  M10.5 Phase A: Intel stub conformers — concretized (no existential protocol types).
//  All types use concrete types matching the Apple Silicon originals byte-for-byte.
//  Protocol conformances dropped — ChatView accesses these directly by type name.
//

#if OSAURUS_INTEL

import CryptoKit
import Foundation
import OsaurusRepository

// MARK: - SpeechService (no-op on Intel)

// MARK: - Voice notification names (Intel stubs)
//
// Upstream declares these in `Services/Voice/VADService.swift` (excluded).
// FloatingInputCard subscribes to both via `NotificationCenter.default`;
// on Intel nothing posts them (no VAD pipeline, no Settings panel) but
// the names still need to resolve at compile time.
extension Notification.Name {
    public static let startVoiceInputInChat = Notification.Name("startVoiceInputInChat")
    public static let voiceConfigurationChanged = Notification.Name("voiceConfigurationChanged")
}

// MARK: - Voice subsystem stubs (Phase 8C)
//
// The entire voice pipeline (SpeechService, SpeechModelManager,
// SpeechConfiguration, LiveVoiceAudioSnapshot, SpeechError,
// TranscriptionCleanupService) lives behind the excluded
// `Services/Voice/*.swift` + `Managers/SpeechService.swift` +
// `Managers/Model/SpeechModelManager.swift` files. FloatingInputCard's
// microphone button + transcription overlay reach deeply into this
// surface, so rather than gate every line in the upstream view, we
// expose no-op stubs here. The buttons render but stay inert; users
// see "microphone permission denied" semantics by default.

struct LiveVoiceAudioSnapshot: Sendable {
    var samples: [Float] = []
    /// Sample rate as `Int` so the Int↔Double comparisons in
    /// FloatingInputCard's `scheduleLiveVoicePreencodeIfNeeded` type-check
    /// without explicit conversion. 16_000 is the standard wav rate the
    /// upstream pipeline uses.
    var sampleRate: Int = 16_000
    /// Seconds-of-audio derived from `samples.count / sampleRate`.
    /// FloatingInputCard logs this on every send; with empty samples
    /// the value is zero.
    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
    /// Best-effort WAV-encoded bytes. Returns nil on Intel because the
    /// stub never carries actual samples; FloatingInputCard handles the
    /// nil case (treats it as "no voice attachment").
    func wavData() -> Data? { nil }
}

enum SpeechError: Error, LocalizedError {
    case unavailable
    case modelNotLoaded
    case permissionDenied
    case microphonePermissionDenied
    case transcriptionFailed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Speech input is not available on Intel."
        case .modelNotLoaded: return "Speech model not loaded."
        case .permissionDenied, .microphonePermissionDenied:
            return "Microphone permission denied."
        case .transcriptionFailed(let detail): return "Transcription failed: \(detail)"
        }
    }
}

/// Return type for `ModelRuntime.preencodeLiveVoiceAudioIfResident` —
/// FloatingInputCard logs every field on completion. Intel never
/// actually produces one (the method returns nil), but the type has
/// to exist for the closure body's `result.status.rawValue` access
/// path to type-check.
struct LiveVoicePreencodeResult: Sendable {
    enum Status: String, Sendable {
        case ok
        case skipped
        case failed
    }
    let status: Status
    let sampleCount: Int
    let sampleRate: Int
    let encodeMs: Int
    let message: String?
}

// `SpeechConfiguration` (with its `.default` static, `confirmationDelay`,
// `pauseDuration`, etc.) is provided by upstream
// `Models/Voice/SpeechConfiguration.swift` (un-excluded — it's pure
// Foundation enums + struct). The stub that used to live here has been
// removed to avoid a redeclaration collision.

final class SpeechService: ObservableObject, @unchecked Sendable {
    static let shared = SpeechService()

    // Recording lifecycle
    @Published var isRecording: Bool = false
    @Published var isSpeechDetected: Bool = false
    @Published var audioLevel: Float = 0

    // Transcription state
    @Published var currentTranscription: String = ""
    @Published var confirmedTranscription: String = ""

    // Model state
    @Published var isLoadingModel: Bool = false
    @Published var isModelLoaded: Bool = false

    // Permission state
    @Published var microphonePermissionGranted: Bool = false

    /// Identifier of the currently-loaded speech model. Always nil on
    /// Intel because the speech subsystem is amputated; surface kept
    /// so `ConfigurationView`'s Voice section (un-body-swapped in M11
    /// Phase 11.A.3.1, gated visually to AppleSiliconOnlyOverlay)
    /// type-checks.
    @Published var loadedModelId: String? = nil

    // Methods — all no-op on Intel
    func stopStreamingTranscription(force: Bool = false) async {}
    func clearTranscription() {}
    func startStreamingTranscription(config: SpeechConfiguration = .default) async throws {
        throw SpeechError.unavailable
    }
    func loadModel(_ modelId: String? = nil) async throws {
        throw SpeechError.modelNotLoaded
    }
    func requestMicrophonePermission() async -> Bool { false }
    /// Live snapshot accessor used by `FloatingInputCard.scheduleLiveVoicePreencodeIfNeeded`.
    /// Upstream is a `currentLiveAudioSnapshot()` method that returns
    /// the latest live VAD frame; Intel has no recording session so
    /// the answer is always nil.
    func currentLiveAudioSnapshot() -> LiveVoiceAudioSnapshot? { nil }
}

final class SpeechModelManager: ObservableObject, @unchecked Sendable {
    static let shared = SpeechModelManager()
    @Published var selectedModel: SpeechModelInfo? = nil
    @Published var availableModels: [SpeechModelInfo] = []
    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    /// Used by FloatingInputCard's "Speech models" sub-popover header.
    /// Always zero on Intel.
    @Published var downloadedModelsCount: Int = 0

    func selectModel(_ model: SpeechModelInfo) {}
    func downloadModel(_ model: SpeechModelInfo) async {}
    func deleteModel(_ model: SpeechModelInfo) {}
}

struct SpeechModelInfo: Identifiable, Sendable, Equatable {
    let id: String
    var name: String = ""
    var isInstalled: Bool = false
    var sizeBytes: Int64 = 0
}

final class TranscriptionCleanupService: @unchecked Sendable {
    static let shared = TranscriptionCleanupService()
    func cleanup(_ text: String) -> String { text }
    func cleanupForSend(_ text: String) -> String { text }
    func clean(_ text: String) -> String { text }
    static func cleanup(_ text: String) -> String { text }
    static func cleanupForSend(_ text: String) -> String { text }
}

// MARK: - ModelManager (Intel stub)
//
// Upstream `Managers/Model/ModelManager.swift` orchestrates the MLX
// local-model lifecycle (download / load / unload / list). Intel has
// zero local models, so the stub exposes only the surface
// FloatingInputCard reads — empty everywhere.

final class ModelManager: ObservableObject, @unchecked Sendable {
    static let shared = ModelManager()
    @Published var availableModels: [ModelInfo] = []
    @Published var suggestedModels: [ModelInfo] = []
    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var downloadMetrics: [String: DownloadMetrics] = [:]

    /// A locally-discovered model reference. ServerView reads `.id`.
    struct LocalModelRef: Sendable { let id: String }

    /// ServerView's API-reference example list calls this to enumerate
    /// locally-downloaded MLX models. Always empty on Intel (local
    /// model execution is amputated). Static to match the upstream
    /// call site `ModelManager.discoverLocalModels()`.
    static func discoverLocalModels() -> [LocalModelRef] { [] }

    enum DownloadState: Sendable, Equatable {
        case idle
        case downloading(Double)
        case completed
        case failed(String)
    }

    struct DownloadMetrics: Sendable {
        var bytesReceived: Int64? = nil
        var totalBytes: Int64? = nil
        var bytesPerSecond: Double? = nil
        var etaSeconds: Double? = nil
    }

    /// Upstream returns a newer model id when a known-deprecated MLX
    /// model gets selected (e.g., Qwen 3 → Qwen 3.5). Intel has no
    /// local-model catalogue, so deprecation never applies.
    static func replacementForDeprecatedModel(_ modelId: String) -> String? { nil }
}

// `ModelFamilyNames` is provided by upstream
// `Models/Configuration/ModelFamilyNames.swift` (not excluded). The
// Intel stub that used to live here was removed to avoid a
// redeclaration collision.

// MARK: - RemoteProviderManager (cloud-only, concretized)
//
// `RemoteProvidersView` (un-body-swapped in M11 Phase 11.A.2) reads
// `manager.configuration.providers` + `manager.providerStates` via
// `@ObservedObject`, and mutates the set via `addProvider`,
// `updateProvider`, `removeProvider`, `setEnabled`. Extended in M11
// Phase 11.A.2.0 to mirror the upstream public surface used by the
// view, with real on-disk persistence via
// `RemoteProviderConfigurationStore` (NOT excluded on Intel — see
// `Models/Configuration/RemoteProviderConfiguration.swift:500`).
// `@MainActor` matches upstream so the view's bindings stay on the
// main actor and Swift 6.3 actor-isolation diagnostics are quiet.
//
// What's deliberately NOT modeled: `connect` / `reconnect` /
// `testConnection` / `service(for:)` / `connectedServices()` — those
// route through `RemoteProviderService` which is excluded on Intel
// (cloud streaming happens via `OsaurusServer` + env-var
// `DEEPSEEK_API_KEY`, not through the configured provider list).
// The Intel stubs for those methods stay as no-ops so any chat-side
// caller doesn't crash.
@MainActor
final class RemoteProviderManager: ObservableObject, @unchecked Sendable {
    static let shared = RemoteProviderManager()

    @Published private(set) var configuration: RemoteProviderConfiguration
    @Published private(set) var providerStates: [UUID: RemoteProviderState] = [:]

    /// Osaurus Router per-model metadata (pricing, context, capabilities),
    /// keyed by model id. Populated by `connectOsaurusRouterIfPossible` from the
    /// catalog and consumed by the model-picker builder to enrich router rows
    /// with a description + Vision badge. `providerStates.discoveredModels` only
    /// carries the bare ids, so this is where the rich metadata lives.
    @Published private(set) var routerModelMetadata: [String: OsaurusRouterModel] = [:]

    /// Vendor-advertised context windows for custom (non-router) providers'
    /// models, keyed by provider id then model id. Populated from the
    /// `/models` discovery probe when a custom OpenAI-compatible endpoint
    /// reports `max_model_len`/`context_length`/`max_context_length` for a
    /// model, so the picker + context-budget logic can honor it instead of
    /// falling back to the generic default.
    @Published private(set) var customProviderContextLengths: [UUID: [String: Int]] = [:]

    func customProviderContextLength(providerId: UUID, modelId: String) -> Int? {
        customProviderContextLengths[providerId]?[modelId]
    }

    private init() {
        self.configuration = RemoteProviderConfigurationStore.load()
        seedConnectedStates()
        // Discover each enabled provider's models in the background so the
        // chat picker + the "N models available" counter populate at launch.
        Task { await refreshAllModels() }
    }

    /// Mark every enabled provider as "connected" so the Providers tab
    /// doesn't show a misleading "Disconnected" badge. On Intel,
    /// streaming goes through `OsaurusServer` + the env-var
    /// `DEEPSEEK_API_KEY` rather than a per-provider connection — so a
    /// configured + enabled provider IS effectively usable, and the
    /// stock "Disconnected" state confused users during the 11.A.2
    /// click-through. (Renée 2026-06-01/02.)
    private func seedConnectedStates() {
        for provider in configuration.providers where provider.enabled {
            var state = RemoteProviderState(providerId: provider.id)
            state.isConnected = true
            providerStates[provider.id] = state
        }
    }

    func isEphemeral(id: UUID) -> Bool { false }

    /// Tell the model picker to rebuild after the provider list changes, so a
    /// newly added/edited provider's models appear in the chat picker without
    /// an app relaunch. `ChatView` and the Intel `ModelPickerItemCache` both
    /// observe this. (Upstream's RemoteProviderService posts it on connect;
    /// Intel routes through env/saved keys, so we post it on config mutation.)
    private func notifyModelsChanged() {
        NotificationCenter.default.post(name: .remoteProviderModelsChanged, object: nil)
    }

    /// GET the provider's `/models` endpoint: returns the discovered model ids
    /// and any vendor-advertised context window reported alongside each id in
    /// the discovery
    /// response (the OpenAI-compatible `data[]` shape only — the `models[]`
    /// fallback branch doesn't carry these vendor keys upstream either, so
    /// it returns an empty context-length map).
    private func probeModelsDiscovery(for provider: RemoteProvider) async throws -> (
        models: [String], contextLengths: [String: Int]
    ) {
        // OAuth providers don't answer a plain `/models` GET, so resolve their
        // catalogs before falling through to the generic probe. Upstream's
        // `RemoteProviderService.fetchModels` branches the same way; this Intel
        // mirror was missing both branches, so signing in to ChatGPT/Codex
        // showed its models during sign-in and then an empty picker forever
        // after — the probe was GETting `chatgpt.com/backend-api/models`
        // unauthenticated and swallowing the non-2xx.
        if let catalog = try await Self.oauthModelCatalog(
            providerType: provider.providerType,
            authType: provider.authType,
            providerId: provider.id
        ) {
            return (catalog, [:])
        }

        var headers = provider.customHeaders
        if provider.authType == .apiKey,
            let key = RemoteProviderKeychain.getAPIKey(for: provider.id),
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch provider.providerType {
            case .anthropic:
                headers["x-api-key"] = key
                if headers["anthropic-version"] == nil { headers["anthropic-version"] = "2023-06-01" }
            case .gemini:
                headers["x-goog-api-key"] = key
            case .azureOpenAI:
                headers["api-key"] = key
            default:
                headers["Authorization"] = "Bearer \(key)"
            }
        }
        guard let url = provider.url(for: "/models") else { return ([], [:]) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, response) = try? await GlobalProxySettings.makeSession().data(for: req),
            let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], [:]) }
        if let arr = json["data"] as? [[String: Any]] {
            var ids: [String] = []
            var lengths: [String: Int] = [:]
            for entry in arr {
                guard let id = entry["id"] as? String else { continue }
                ids.append(id)
                let candidates = [entry["max_model_len"], entry["context_length"], entry["max_context_length"]]
                for raw in candidates {
                    if let n = raw as? Int, n > 0 {
                        lengths[id] = n
                        break
                    }
                    if let d = raw as? Double, d.isFinite, d > 0 {
                        lengths[id] = Int(d)
                        break
                    }
                    if let s = raw as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)), n > 0 {
                        lengths[id] = n
                        break
                    }
                }
            }
            return (ids.sorted(), lengths)
        }
        if let arr = json["models"] as? [[String: Any]] {
            let ids = arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
            return (ids, [:])
        }
        return ([], [:])
    }

    /// Probe one enabled provider and cache its models into
    /// `providerStates[id].discoveredModels` (which feeds the "N models
    /// available" counter, the chat picker, and `CloudChatEngine` routing),
    /// then notify observers.
    func refreshModels(for providerId: UUID) async {
        guard let provider = configuration.providers.first(where: { $0.id == providerId }),
            provider.enabled
        else { return }
        do {
            let (models, contextLengths) = try await probeModelsDiscovery(for: provider)
            var state = providerStates[providerId] ?? RemoteProviderState(providerId: providerId)
            state.isConnected = true
            state.lastError = nil
            state.discoveredModels = models
            state.lastConnectedAt = Date()
            providerStates[providerId] = state
            customProviderContextLengths[providerId] = contextLengths
            NSLog("[RemoteProviderManager] \(provider.name): discovered \(models.count) model(s) → \(models)")
            notifyModelsChanged()
        } catch {
            var state = providerStates[providerId] ?? RemoteProviderState(providerId: providerId)
            state.isConnected = false
            state.lastError = error.localizedDescription
            providerStates[providerId] = state
            notifyModelsChanged()
        }
    }

    /// Probe every enabled provider. Called at launch, when the Providers tab
    /// appears (so a late-started local server is picked up), and after any
    /// provider mutation.
    func refreshAllModels() async {
        let enabled = configuration.providers.filter { $0.enabled }
        for provider in enabled {
            // The Osaurus Router's catalog lives behind an EIP-191-signed account
            // API (GET /models at the host root), not the plain unsigned /models
            // probe `probeModelsDiscovery` does — an unsigned probe just 404s/401s, leaving
            // the router with zero models until the Credits tab happened to run the
            // signed fetch. Route it through the signed path so the catalog (and
            // its pricing/vision metadata) populates at launch like every other
            // provider. (Fixes: only DeepSeek showed in the picker on a fresh start.)
            if provider.providerType == .osaurusRouter {
                await connectOsaurusRouterIfPossible()
                continue
            }
            do {
                let (models, contextLengths) = try await probeModelsDiscovery(for: provider)
                var state = providerStates[provider.id] ?? RemoteProviderState(providerId: provider.id)
                state.isConnected = true
                state.lastError = nil
                state.discoveredModels = models
                state.lastConnectedAt = Date()
                providerStates[provider.id] = state
                customProviderContextLengths[provider.id] = contextLengths
                NSLog("[RemoteProviderManager] \(provider.name): discovered \(models.count) model(s) → \(models)")
            } catch {
                var state = providerStates[provider.id] ?? RemoteProviderState(providerId: provider.id)
                state.isConnected = false
                state.lastError = error.localizedDescription
                providerStates[provider.id] = state
            }
        }
        notifyModelsChanged()
    }

    // MARK: - Osaurus Router (hosted inference)

    /// Stable identity for the managed Osaurus Router provider (mirrors upstream).
    static let osaurusRouterProviderId = UUID(uuidString: "2CFBD528-62FD-4EF0-A143-3FE532F03840")!

    /// The managed provider pointing the engine at `router.osaurus.ai`. `authType`
    /// is `.none` — the EIP-191 wallet signature is applied per-request by
    /// `CloudChatEngine` via `OsaurusRouterAuthSigner`, not a stored API key.
    private static func makeManagedOsaurusRouterProvider() -> RemoteProvider {
        RemoteProvider(
            id: osaurusRouterProviderId,
            name: "Osaurus",
            host: OsaurusRouter.defaultBaseURL.host ?? "router.osaurus.ai",
            providerProtocol: OsaurusRouter.defaultBaseURL.scheme == "http" ? .http : .https,
            port: OsaurusRouter.defaultBaseURL.port,
            basePath: "",
            authType: .none,
            providerType: .osaurusRouter,
            enabled: true,
            autoConnect: true,
            timeout: 120
        )
    }

    /// (Intel) Register the managed Osaurus Router provider (if absent) and refresh
    /// its model catalog via the signed account API. Called by
    /// `OsaurusRouterAccountService` once a wallet identity exists. Upstream routes
    /// this through `RemoteProviderService.connect`; Intel registers the provider
    /// directly so `CloudChatEngine` resolves the router endpoint + signed auth.
    func connectOsaurusRouterIfPossible() async {
        if !configuration.providers.contains(where: { $0.id == Self.osaurusRouterProviderId }) {
            configuration.add(Self.makeManagedOsaurusRouterProvider())
        }
        var state = providerStates[Self.osaurusRouterProviderId]
            ?? RemoteProviderState(providerId: Self.osaurusRouterProviderId)
        state.isConnected = true
        if let models = try? await OsaurusRouterAPIClient().models() {
            state.discoveredModels = models.map(\.id).sorted()
            state.lastConnectedAt = Date()
            routerModelMetadata = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        }
        providerStates[Self.osaurusRouterProviderId] = state
        notifyModelsChanged()
    }

    func addProvider(
        _ provider: RemoteProvider,
        apiKey: String? = nil,
        oauthTokens: RemoteProviderOAuthTokens? = nil,
        isEphemeral: Bool = false
    ) {
        configuration.add(provider)
        RemoteProviderConfigurationStore.save(configuration)
        persistCredentials(apiKey: apiKey, oauthTokens: oauthTokens, for: provider.id)
        if provider.enabled {
            var state = RemoteProviderState(providerId: provider.id)
            state.isConnected = true
            providerStates[provider.id] = state
        }
        notifyModelsChanged()
        Task { await refreshModels(for: provider.id) }
    }

    func updateProvider(
        _ provider: RemoteProvider,
        apiKey: String? = nil,
        oauthTokens: RemoteProviderOAuthTokens? = nil
    ) {
        configuration.update(provider)
        RemoteProviderConfigurationStore.save(configuration)
        persistCredentials(apiKey: apiKey, oauthTokens: oauthTokens, for: provider.id)
        notifyModelsChanged()
        Task { await refreshModels(for: provider.id) }
    }

    func removeProvider(id: UUID) {
        configuration.remove(id: id)
        providerStates.removeValue(forKey: id)
        RemoteProviderConfigurationStore.save(configuration)
        RemoteProviderKeychain.deleteAPIKey(for: id)
        RemoteProviderKeychain.deleteOAuthTokens(for: id)
        notifyModelsChanged()
    }

    /// Persist the credential the user typed in Settings → Providers. The
    /// original Intel mirror dropped the `apiKey` entirely (it assumed the
    /// `DEEPSEEK_API_KEY` env var), so a double-clicked app — e.g. on Rosy with
    /// no env var — never had a key. `nil` apiKey means "keep current" (the edit
    /// dialog passes nil when the field is left blank), so only overwrite when a
    /// non-empty key is provided.
    private func persistCredentials(
        apiKey: String?, oauthTokens: RemoteProviderOAuthTokens?, for providerId: UUID
    ) {
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RemoteProviderKeychain.saveAPIKey(apiKey, for: providerId)
        } else if let oauthTokens {
            RemoteProviderKeychain.saveOAuthTokens(oauthTokens, for: providerId)
        }
    }

    func setEnabled(_ enabled: Bool, for providerId: UUID) {
        configuration.setEnabled(enabled, for: providerId)
        RemoteProviderConfigurationStore.save(configuration)
        if enabled {
            var state = RemoteProviderState(providerId: providerId)
            state.isConnected = true
            providerStates[providerId] = state
            notifyModelsChanged()
            Task { await refreshModels(for: providerId) }
        } else {
            providerStates.removeValue(forKey: providerId)
            notifyModelsChanged()
        }
    }

    /// Persist a new provider order (drag-to-reorder sheet). The order is
    /// reflected in the provider list AND the chat model picker, which both
    /// iterate `configuration.providers`.
    func reorder(orderedIds: [UUID]) {
        configuration.reorder(orderedIds: orderedIds)
        RemoteProviderConfigurationStore.save(configuration)
        notifyModelsChanged()
    }

    // Cloud-routing no-ops kept for compatibility with chat-side callers.
    func connect(providerId: UUID) async throws {}
    func disconnect(providerId: UUID) {}
    func reconnect(providerId: UUID) async throws {}

    /// AgentDetailView's per-agent model picker calls `findService` to
    /// resolve a provider's live connection. Cloud streaming on Intel
    /// goes through `OsaurusServer` + the env-var key, not through a
    /// per-provider service object, so this returns nil.
    func findService(forModel model: String) -> Any? { nil }

    /// M12 follow-up (Renée 2026-06-03): the RemoteProviderEditSheet "Test"
    /// step probes the provider's `/models` endpoint. The upstream
    /// `RemoteProviderManager.testConnection` (excluded) pulls in
    /// `RemoteProviderService` + OAuth + Anthropic-specific helpers; this is a
    /// pragmatic Intel mirror that does the OpenAI-compatible GET /models probe
    /// (which covers DeepSeek and friends) so add/edit actually works. Returns
    /// the discovered model ids.
    /// Model catalog for providers whose credentials aren't an API key, or nil
    /// when the caller should fall through to the generic `/models` probe.
    ///
    /// - ChatGPT/Codex: refreshes an expired token (persisting the result) and
    ///   asks the service, which does a live fetch and falls back to its
    ///   built-in list. With no `providerId` there are no tokens to read, so
    ///   the built-in list is returned directly.
    /// - xAI (Grok): OAuth tokens are refused by `/models` with HTTP 403
    ///   upstream, so the built-in catalog is the only answer available.
    // Internal (not private) for direct testing.
    static func oauthModelCatalog(
        providerType: RemoteProviderType,
        authType: RemoteProviderAuthType,
        providerId: UUID?,
        strict: Bool = false
    ) async throws -> [String]? {
        if providerType == .openAICodex || authType == .openAICodexOAuth {
            guard let providerId else {
                if strict { throw IntelCodexCredentialsError.missing(providerId: UUID()) }
                return OpenAICodexOAuthService.supportedModels
            }
            let tokens = try await IntelCodexCredentials.shared.tokens(for: providerId)
            do {
                return try await OpenAICodexOAuthService.fetchAvailableModels(tokens: tokens)
            } catch {
                if strict { throw error }
                return OpenAICodexOAuthService.supportedModels
            }
        }
        if authType == .xaiOAuth {
            return XAIOAuthService.supportedModels
        }
        return nil
    }

    func testConnection(
        host: String,
        providerProtocol: RemoteProviderProtocol,
        port: Int?,
        basePath: String,
        authType: RemoteProviderAuthType,
        providerType: RemoteProviderType = .openaiLegacy,
        apiKey: String?,
        headers: [String: String],
        providerId: UUID? = nil
    ) async throws -> [String] {
        // The Osaurus Router rejects a plain unsigned /models probe (its catalog
        // is behind the EIP-191-signed account API), so the generic probe below
        // would always fail "Test" for it. Validate the router via the signed
        // catalog fetch instead — the same call that populates the picker.
        if providerType == .osaurusRouter {
            return try await OsaurusRouterAPIClient().models().map(\.id).sorted()
        }

        if let catalog = try await Self.oauthModelCatalog(
            providerType: providerType,
            authType: authType,
            providerId: providerId,
            strict: true
        ) {
            return catalog
        }

        let tempProvider = RemoteProvider(
            name: "Test",
            host: host,
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            customHeaders: headers,
            authType: authType,
            providerType: providerType,
            enabled: true,
            autoConnect: false,
            timeout: 30
        )

        var testHeaders = headers
        if authType == .apiKey, let apiKey, !apiKey.isEmpty {
            switch providerType {
            case .anthropic:
                if testHeaders["x-api-key"] == nil { testHeaders["x-api-key"] = apiKey }
                if testHeaders["anthropic-version"] == nil {
                    testHeaders["anthropic-version"] = "2023-06-01"
                }
            case .gemini:
                if testHeaders["x-goog-api-key"] == nil { testHeaders["x-goog-api-key"] = apiKey }
            case .azureOpenAI:
                if testHeaders["api-key"] == nil { testHeaders["api-key"] = apiKey }
            default:
                if testHeaders["Authorization"] == nil {
                    testHeaders["Authorization"] = "Bearer \(apiKey)"
                }
            }
        }

        guard let url = tempProvider.url(for: "/models") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (k, v) in testHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await GlobalProxySettings.makeSession().data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "RemoteProvider",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Test failed — HTTP \(http.statusCode)"]
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        if let arr = json["data"] as? [[String: Any]] {
            return arr.compactMap { $0["id"] as? String }.sorted()
        }
        if let arr = json["models"] as? [[String: Any]] {
            return arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
        }
        return []
    }
}

// MARK: - PluginRepositoryService (Intel stub)
//
// Upstream `PluginRepositoryService` (excluded on Intel — see
// `Services/Plugin/PluginRepositoryService.swift`) tracks installed
// + repository-known plugins and is referenced by `SkillsView` (un-
// body-swapped in M11 Phase 11.A.2) when rendering "From: <plugin>"
// breadcrumbs on plugin-attached skills.
//
// On Intel this stub does double duty:
//   PATH A (current): fetches the plugin index from the osaurus-intel-plugins
//     repo via URLSession, merges Intel-native entries into Browse.
//   Upstream Browse: continues to fetch the arm64 registry via
//     CentralRepositoryManager (M9 Phase A).
//
// PATH B (future): replace the URLSession index fetch with a second
// CentralRepositoryManager instance pointed at the Intel plugin repo's
// plugins/*.json PluginSpec files. The CPUArch enum needs .x86_64 added,
// and PluginInstallManager needs a targetArch parameter.
@MainActor
final class PluginRepositoryService: ObservableObject, @unchecked Sendable {
    static let shared = PluginRepositoryService()

    /// PATH A: the lightweight plugins.json index served by the Intel plugin repo.
    /// PATH B: replace usage of this with CentralRepositoryManager pointed at the
    /// same repo's plugins/ directory.
    private static let intelPluginIndexURL = URL(
        string: "https://raw.githubusercontent.com/reneezmp/osaurus-intel-plugins/main/plugins.json"
    )!

    @Published private(set) var plugins: [PluginState] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published var updatesAvailableCount: Int = 0
    @Published var lastError: String? = nil
    @Published var pendingSecretsPlugin: String? = nil

    /// PATH A index cache. Re-fetched on every refresh().
    private var intelIndexEntries: [IntelPluginIndexEntry] = []

    private init() {}

    // MARK: - Install / Uninstall / Upgrade

    /// Uninstall a plugin: delete its directory under Tools/ and reload.
    func uninstall(pluginId: String) async {
        let dir = OsaurusPaths.pluginDirectory(for: pluginId)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        await PluginManager.shared.loadAll()
        await refreshLocalState()
    }

    /// Install an Intel-native plugin: download dylib + manifest, verify SHA256,
    /// place in Tools/<pluginId>/, reload.
    func install(pluginId: String) async throws {
        guard let entry = intelIndexEntries.first(where: { $0.id == pluginId }),
              let stateIdx = plugins.firstIndex(where: { $0.pluginId == pluginId })
        else { return }

        await MainActor.run { plugins[stateIdx].isInstalling = true }

        do {
            let dir = OsaurusPaths.pluginDirectory(for: pluginId)
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)

            // Download dylib
            guard let dylibRemote = URL(string: entry.download_url) else {
                throw PluginInstallError.badURL(entry.download_url)
            }
            let dylibURL = dir.appendingPathComponent("plugin.dylib")
            let (dylibData, _) = try await GlobalProxySettings.makeSession().data(from: dylibRemote)

            // Verify SHA256 BEFORE writing anything executable to disk.
            let actualSHA = dylibData.sha256()
            guard actualSHA.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
                throw PluginInstallError.sha256Mismatch(expected: entry.sha256, actual: actualSHA)
            }
            try dylibData.write(to: dylibURL)

            // Download manifest
            guard let manifestRemote = URL(string: entry.manifest_url) else {
                throw PluginInstallError.badURL(entry.manifest_url)
            }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            let (manifestData, _) = try await GlobalProxySettings.makeSession().data(from: manifestRemote)
            try manifestData.write(to: manifestURL)

            // Load the plugin
            await PluginManager.shared.loadAll()
            await refreshLocalState()

            await MainActor.run { plugins[stateIdx].isInstalling = false }
        } catch {
            await MainActor.run {
                plugins[stateIdx].isInstalling = false
                plugins[stateIdx].loadError = error.localizedDescription
            }
            throw error
        }
    }

    /// Upgrade: same as install (overwrite existing dylib + manifest).
    func upgrade(pluginId: String) async throws {
        try await install(pluginId: pluginId)
    }

    // MARK: - Refresh (upstream arm64 + Intel index)

    /// Refresh the plugin list from both the upstream arm64 registry (CentralRepositoryManager)
    /// and the Intel-native plugin index (plugins.json). Merges both into `plugins`.
    func refresh() async {
        if isRefreshing { return }
        await MainActor.run {
            isRefreshing = true
            lastError = nil
        }

        // --- Upstream arm64 registry (Browse-only) ---
        let reachable = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.refresh()
        }.value
        let specs = await Task.detached(priority: .utility) {
            CentralRepositoryManager.shared.listAllSpecs()
        }.value
        let upstreamMapped: [PluginState] = specs.map { spec in
            let latest = spec.versions.map(\.version).max()
            let hasX86 = spec.versions.contains { entry in
                entry.artifacts.contains { $0.arch == "x86_64" }
            }
            return PluginState(
                pluginId: spec.plugin_id,
                name: spec.name,
                pluginDescription: spec.description,
                authors: spec.authors,
                license: spec.license,
                capabilities: nil,
                installedVersion: nil,
                latestVersion: latest.map {
                    SemanticVersion(major: $0.major, minor: $0.minor, patch: $0.patch)
                },
                isInstalling: false,
                loadError: nil,
                requiresAppleSilicon: !hasX86
            )
        }

        // --- Intel-native plugin index (PATH A: URLSession) ---
        // PATH B (future): replace this block with a second CentralRepositoryManager
        // fetch against the Intel repo's plugins/*.json. The entries carry
        // x86_64 artifacts; PluginInstallManager would need targetArch
        // plumbing. The index types above (IntelPluginIndexEntry) would be
        // replaced by PluginSpec mapping.
        var intelMapped: [PluginState] = []
        do {
            let (data, _) = try await GlobalProxySettings.makeSession().data(from: Self.intelPluginIndexURL)
            let index = try JSONDecoder().decode(IntelPluginIndex.self, from: data)
            intelIndexEntries = index.plugins
            intelMapped = index.plugins.map { entry in
                let semver = parseSemver(entry.version)
                // Check if this plugin is already installed locally
                let installed = PluginManager.shared.isNativelyLoaded(pluginId: entry.id)
                return PluginState(
                    pluginId: entry.id,
                    name: entry.name,
                    pluginDescription: entry.description,
                    authors: entry.authors,
                    license: nil,
                    // Carry the index's declared tools through so the Tools tab's
                    // "Plugin Tools" section (which reads capabilities?.tools) can
                    // surface them and let the user set per-tool policies. Without
                    // this the tools work in chat but never appear in the UI.
                    capabilities: RegistryCapabilities(
                        tools: entry.tools.map {
                            RegistryCapabilities.ToolSummary(name: $0.id, description: $0.description)
                        }
                    ),
                    installedVersion: installed
                        ? (installedManifestVersion(for: entry.id) ?? semver) : nil,
                    latestVersion: semver,
                    isInstalling: false,
                    loadError: nil,
                    requiresAppleSilicon: false,
                    downloadURL: entry.download_url,
                    manifestURL: entry.manifest_url,
                    expectedSHA256: entry.sha256
                )
            }
        } catch {
            // Non-fatal: upstream Browse still works even if the Intel index is down.
            // PATH B note: CentralRepositoryManager has its own caching; a failed
            // fetch would similarly leave the Intel list empty without killing upstream.
            NSLog("[Osaurus Intel] plugin index fetch failed: \(error.localizedDescription)")
        }

        await MainActor.run {
            if !reachable && upstreamMapped.isEmpty && intelMapped.isEmpty {
                lastError = "Unable to reach the plugin repository"
            }
            // Merge: upstream arm64 + Intel-native, sorted by display name
            let merged = (upstreamMapped + intelMapped).sorted {
                ($0.name ?? $0.pluginId) < ($1.name ?? $1.pluginId)
            }
            plugins = merged
            updatesAvailableCount = merged.filter { $0.hasUpdate }.count
            isRefreshing = false
        }
    }

    // MARK: - Helpers

    /// Refresh installedVersion / loadError in the local state after a loadAll().
    private func refreshLocalState() async {
        await MainActor.run {
            for i in plugins.indices {
                let pid = plugins[i].pluginId
                if PluginManager.shared.isNativelyLoaded(pluginId: pid) {
                    // Read the genuine installed version off disk so an upgrade
                    // (which overwrites the manifest) correctly clears hasUpdate,
                    // and a still-outdated install keeps showing it.
                    plugins[i].installedVersion =
                        installedManifestVersion(for: pid) ?? plugins[i].latestVersion
                    plugins[i].loadError = nil
                } else {
                    plugins[i].installedVersion = nil
                }
            }
            updatesAvailableCount = plugins.filter { $0.hasUpdate }.count
        }
    }
}

private func parseSemver(_ s: String) -> SemanticVersion? {
    let parts = s.split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return nil }
    return SemanticVersion(
        major: parts[0],
        minor: parts[1],
        patch: parts.count > 2 ? parts[2] : 0
    )
}

/// Read the *actually installed* version from a plugin's on-disk manifest.json.
/// This is what makes update detection real: the index carries `latestVersion`,
/// and comparing it against the genuine installed version (not "assume it's the
/// latest") is the difference between `hasUpdate` ever being true or not.
private func installedManifestVersion(for pluginId: String) -> SemanticVersion? {
    let manifestURL = OsaurusPaths.pluginDirectory(for: pluginId)
        .appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: manifestURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let v = json["version"] as? String
    else { return nil }
    return parseSemver(v)
}

private enum PluginInstallError: Error, LocalizedError {
    case sha256Mismatch(expected: String, actual: String)
    case badURL(String)

    var errorDescription: String? {
        switch self {
        case .sha256Mismatch(let expected, let actual):
            return "Download verification failed. Expected SHA256 \(expected.prefix(16))…, got \(actual.prefix(16))…"
        case .badURL(let url):
            return "The plugin index contained an invalid URL: \(url)"
        }
    }
}

/// Intel stub mirroring just the surface `SkillsView` reads off
/// `PluginRepositoryService.shared.plugins.first(where:)`. Upstream
/// definition at `Services/Plugin/PluginRepositoryService.swift:14`
/// has the full plugin metadata; Intel keeps only `pluginId` +
/// `displayName` since the only caller is the breadcrumb in SkillRow.
// Full PluginState shape (M11 Phase 11.B.2) mirroring upstream
// `Services/Plugin/PluginRepositoryService.swift`. The PluginsView
// three-bucket UI reads display metadata + install/update state. Empty
// on Intel (no plugin runtime), but the full shape must compile.
struct PluginState: Identifiable, Equatable {
    let pluginId: String
    var id: String { pluginId }
    let name: String?
    let pluginDescription: String?
    let authors: [String]?
    let license: String?
    let capabilities: RegistryCapabilities?
    var installedVersion: SemanticVersion?
    var latestVersion: SemanticVersion?
    var isInstalling: Bool
    var loadError: String?
    /// M9 Phase B (Intel): true when the registry has no x86_64 artifact for
    /// this plugin (i.e. it's arm64-only and can't load on this Intel build).
    /// Drives the "Apple Silicon required" badge + disabled Install in PluginsView.
    var requiresAppleSilicon: Bool = false
    /// Intel plugin repo: download URL for the pre-built x86_64 dylib. Nil for
    /// upstream arm64 plugins and for Intel plugins that haven't been fetched yet.
    var downloadURL: String?
    /// Intel plugin repo: manifest.json URL (runtime manifest, not PluginSpec).
    var manifestURL: String?
    /// Intel plugin repo: expected SHA256 of the dylib at downloadURL.
    var expectedSHA256: String?

    var displayName: String { name ?? pluginId }
    var hasUpdate: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return latest > installed
    }
    var isInstalled: Bool { installedVersion != nil }
    var hasLoadError: Bool { isInstalled && loadError != nil }

    init(
        pluginId: String,
        name: String? = nil,
        pluginDescription: String? = nil,
        authors: [String]? = nil,
        license: String? = nil,
        capabilities: RegistryCapabilities? = nil,
        installedVersion: SemanticVersion? = nil,
        latestVersion: SemanticVersion? = nil,
        isInstalling: Bool = false,
        loadError: String? = nil,
        requiresAppleSilicon: Bool = false,
        downloadURL: String? = nil,
        manifestURL: String? = nil,
        expectedSHA256: String? = nil
    ) {
        self.pluginId = pluginId
        self.name = name
        self.pluginDescription = pluginDescription
        self.authors = authors
        self.license = license
        self.capabilities = capabilities
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.isInstalling = isInstalling
        self.loadError = loadError
        self.requiresAppleSilicon = requiresAppleSilicon
        self.downloadURL = downloadURL
        self.manifestURL = manifestURL
        self.expectedSHA256 = expectedSHA256
    }
}

// MARK: - Intel Plugin Index (Path A fetch types)
//
// The osaurus-intel-plugins repo serves a plugins.json index that the app
// fetches in one HTTP request. These types decode that index.
//
// PATH B (future): when the plugin count justifies it, replace this with a
// second CentralRepositoryManager instance pointed at the same repo's
// plugins/*.json PluginSpec files. The repo already carries those files;
// the index is a denormalized cache for the lightweight Path A fetch.

private struct IntelPluginIndex: Codable {
    let version: Int
    let plugins: [IntelPluginIndexEntry]
}

private struct IntelPluginIndexEntry: Codable {
    let id: String
    let name: String
    let version: String
    let description: String
    let authors: [String]?
    let tools: [IntelPluginToolEntry]
    let download_url: String
    let manifest_url: String
    let sha256: String
    let size: Int?
    let instructions: String?
    let secrets: [IntelPluginSecretEntry]?
}

private struct IntelPluginToolEntry: Codable {
    let id: String
    let description: String
}

private struct IntelPluginSecretEntry: Codable {
    let id: String
    let label: String
    let description: String?
    let required: Bool
    let secret: Bool
    let url: String?
}

// MARK: - ClaudePluginInstallReport (Intel stub)
//
// Upstream `ClaudePluginInstallReport` lives in the excluded
// `Services/Skill/ClaudePluginInstaller.swift`. The type only
// surfaces through `GitHubImportSheet.onPluginInstallComplete:
// ((ClaudePluginInstallReport) -> Void)?` and the closure body at
// `SkillsView:190` reads four computed totals. The Intel stub
// returns zeros because the GitHub-installer path itself is Apple-
// Silicon only (its sheet renders the `AppleSiliconOnlyTab`
// placeholder), so the callback will never fire with non-zero
// counts on Intel.
public struct ClaudePluginInstallReport: Sendable {
    public init() {}
    public var totalImportedSkills: Int { 0 }
    public var totalImportedAgents: Int { 0 }
    public var totalImportedCommands: Int { 0 }
    public var totalImportedMCPProviders: Int { 0 }
}

// MARK: - ToolRegistry (stub)

final class ToolRegistry: ObservableObject, @unchecked Sendable {
    static let shared = ToolRegistry()

    init() {
        loadPersistedPolicies()
        registerKnowledgeTools()
    }

    func resolveExecutionMode(folderContext: FolderContext?, autonomousEnabled: Bool) -> ExecutionMode { .none }

    // M12 Gap 3: real tool storage + dispatch. The Intel chat already runs the
    // full agent tool-loop (ChatView sends `toolSpecs` and calls
    // `ToolRegistry.shared.execute`); it was inert only because this registry
    // held nothing and `execute` returned canned text. Folder tools
    // (file_read/write/edit/search/tree, shell_run, git_*) register here via
    // FolderToolManager when a working folder is selected, and unregister when
    // it's cleared. No sandbox/DB/capability built-ins (those are amputated) —
    // the folder tool suite is the Intel-supported set.
    private var toolsByName: [String: OsaurusTool] = [:]

    /// Knowledge retrieval is a real built-in on Intel. Visibility is gated
    /// by the agent/project grant scope at prompt composition and again at
    /// execution time inside each tool; registration itself is global so the
    /// tool loop can resolve an approved call without per-agent mutation.
    private func registerKnowledgeTools() {
        let tools: [OsaurusTool] = [
            SearchKnowledgeTool(),
            ReadKnowledgeTool(),
            ListKnowledgeTool(),
        ]
        for tool in tools {
            toolsByName[tool.name] = tool
            builtInToolNames.insert(tool.name)
        }
    }

    /// Register (or overwrite) a tool by name. Used by FolderToolManager.
    func register(_ tool: OsaurusTool) {
        toolsByName[tool.name] = tool
        objectWillChange.send()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Names of remote MCP-provider tools (tracked so the capability picker can
    /// bucket them under their provider). M12 follow-up.
    private var mcpToolNames: Set<String> = []

    /// Register a remote MCP provider's tool. The real MCPProviderManager
    /// (un-excluded) registers each connected remote tool here so the chat
    /// tool-loop + ToolsManagerView + capability picker see them.
    func registerMCPTool(_ tool: OsaurusTool) {
        mcpToolNames.insert(tool.name)
        register(tool)
    }

    /// Native (this-fork) plugin tools: toolName -> plugin display name. Lets
    /// the capability picker bucket them under their plugin and the Tools tab
    /// surface them, just like MCP-provider tools.
    private var pluginToolGroups: [String: String] = [:]

    /// Register a native plugin's tool, grouped under `group` (the plugin's
    /// display name) so it shows as a selectable per-plugin capability.
    func registerPluginTool(_ tool: OsaurusTool, group: String) {
        pluginToolGroups[tool.name] = group
        register(tool)
    }

    /// Tool names belonging to native plugins (for the Tools tab grouping).
    var pluginToolNames: Set<String> { Set(pluginToolGroups.keys) }

    // MARK: Tool source predicates (for AgentCapabilityManagerView grouping)

    /// Always-loaded built-in tools. Intel has none (folder tools are
    /// folder-scoped, not always-loaded built-ins), so this stays empty.
    private(set) var builtInToolNames: Set<String> = []

    /// Built-in sandbox tool names. Amputated on Intel — always empty.
    var builtInSandboxToolNames: Set<String> { [] }

    /// Read-only snapshot of built-in sandbox tool names (mirrors upstream).
    var builtInSandboxToolNamesSnapshot: Set<String> { builtInSandboxToolNames }

    /// Folder-scoped tools provided by FolderToolManager (file_read, file_write,
    /// shell_run, etc.). FolderToolManager is un-excluded on Intel.
    static var folderToolNames: Set<String> {
        MainActor.assumeIsolated {
            Set(FolderToolManager.shared.folderToolNames)
        }
    }

    /// Runtime-managed tools = folder tools + built-in sandbox tools.
    /// Mirrors upstream: `folderToolNames.union(builtInSandboxToolNames)`.
    var runtimeManagedToolNames: Set<String> {
        Self.folderToolNames.union(builtInSandboxToolNames)
    }

    func isMCPTool(_ name: String) -> Bool { mcpToolNames.contains(name) }

    /// Native x86_64 plugin tools (this fork). True for tools registered via
    /// `registerPluginTool` so the picker buckets them under their plugin.
    func isPluginTool(_ name: String) -> Bool { pluginToolGroups[name] != nil }

    /// Sandbox tools are amputated on Intel.
    func isSandboxTool(_ name: String) -> Bool { false }

    /// The provider/plugin group a tool belongs to: MCP provider name for
    /// remote tools, the plugin display name for native plugin tools.
    func groupName(for toolName: String) -> String? {
        if let group = pluginToolGroups[toolName] { return group }
        guard let tool = toolsByName[toolName] else { return nil }
        if let mcp = tool as? MCPProviderTool { return mcp.providerName }
        return nil
    }

    /// Remove tools by name. Used by FolderToolManager when the folder clears
    /// and by MCPProviderManager on disconnect.
    func unregister(names: [String]) {
        guard !names.isEmpty else { return }
        for name in names {
            toolsByName.removeValue(forKey: name)
            mcpToolNames.remove(name)
            pluginToolGroups.removeValue(forKey: name)
        }
        objectWillChange.send()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Tool names the user has switched OFF in the Tools tab. Excluded from
    /// `openAISpecs()` (the model never sees them) and reported by `listTools`.
    /// Session-scoped; survives a tab reload (register doesn't clear it).
    private var disabledToolNames: Set<String> = []

    /// OpenAI-compatible specs for the currently registered tools, fed into
    /// `ComposedContext.tools` so the model sees them on the next send.
    /// Globally-disabled tools are filtered out.
    func openAISpecs() -> [Tool] {
        toolsByName.values
            .filter { !disabledToolNames.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map { $0.asOpenAITool() }
    }

    func execute(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = toolsByName[name] else {
            return ToolEnvelope.failure(
                kind: .toolNotFound,
                message:
                    "Tool '\(name)' is not registered. Pick a working folder to enable file/shell tools.",
                tool: name
            )
        }
        return try await tool.execute(argumentsJSON: argumentsJSON)
    }

    /// Mirror of upstream's `invalidToolArgumentsEnvelope`. When the model
    /// hallucinates tool arguments (detected by the caller via `_error:
    /// "invalid_tool_arguments"` in the result JSON), this returns a
    /// `ToolEnvelope.failure()` with diagnostic metadata so the agent loop
    /// can retry rather than treating the hallucination as a real tool error.
    static func invalidToolArgumentsEnvelope(
        _ argumentsJSON: String,
        toolName: String
    ) -> String? {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["_error"] as? String == "invalid_tool_arguments"
        else { return nil }

        let message = object["_message"] as? String ?? "invalid tool arguments"
        let field = object["_field"] as? String
        let expected = object["_expected"] as? String
        return ToolEnvelope.failure(
            kind: .invalidArgs,
            message: message,
            field: field,
            expected: expected,
            tool: toolName,
            retryable: true
        )
    }

    /// Per-tool allow/deny policy state for `ConfigurationView`'s tool
    /// permission rows (un-body-swapped in M11 Phase 11.A.3.1). Intel
    /// keeps an in-memory map keyed by tool name. Unlike upstream —
    /// which persists policies to `tools.json` and enforces them in
    /// the sandbox executor — Intel's policy state is advisory only
    /// (sandbox tools are amputated; cloud tools run unconditionally).
    /// The map exists so the per-tool segmented picker round-trips and
    /// the `@Published`-style republish via `objectWillChange` keeps
    /// other rows in sync. Stored on the registry; reads/writes are
    /// main-thread (the view drives them).
    private var _policies: [String: ToolPermissionPolicy] = [:]

    /// Returns the configured policy for `toolName`, or nil if the
    /// user hasn't set one (meaning "Auto" / inherit-default).
    func configuredPolicy(for toolName: String) -> ToolPermissionPolicy? {
        _policies[toolName]
    }

    /// Sets the policy for `toolName` and republishes so observing rows
    /// refresh. Stores ALL three values explicitly — including `.auto`.
    ///
    /// Earlier this collapsed `.auto` into a `removeValue` (treating
    /// Auto as "clear the override"). That broke the picker for
    /// destructive tools: `shell_run` and `git_commit` default to
    /// `.ask`, so selecting "Auto" cleared the override, the
    /// `effectivePolicy` fell back to the `.ask` default, and the
    /// segmented control immediately snapped back to Ask — making
    /// Auto un-selectable. Storing the value explicitly lets the
    /// picker's `get: { configuredPolicy ?? defaultPolicy }` read
    /// back the user's actual choice. (M11 Phase 11.A.3 click-through
    /// fix, Renée 2026-06-01.)
    func setPolicy(_ policy: ToolPermissionPolicy, for toolName: String) {
        objectWillChange.send()
        _policies[toolName] = policy
        persistPolicies()
    }

    /// Used by `ConfigurationView`'s per-tool permission rows to clear
    /// a custom allow/deny policy back to the inherited default.
    func clearPolicy(for toolName: String) {
        objectWillChange.send()
        _policies.removeValue(forKey: toolName)
        persistPolicies()
    }

    // MARK: - Policy persistence (Intel)
    //
    // Upstream persists tool policies + enabled flags to disk and reloads them.
    // The Intel mirror previously kept both in memory only, so choices in the
    // Tools / Permissions tabs were lost on restart. Persist to
    // ~/.osaurus/config/tool-policies.json and load on init.
    private struct PolicyDisk: Codable {
        var disabled: [String] = []
        var policies: [String: ToolPermissionPolicy] = [:]
    }

    private static func policiesFileURL() -> URL {
        OsaurusPaths.config().appendingPathComponent("tool-policies.json")
    }

    private func loadPersistedPolicies() {
        guard let data = try? Data(contentsOf: Self.policiesFileURL()),
            let disk = try? JSONDecoder().decode(PolicyDisk.self, from: data)
        else { return }
        disabledToolNames = Set(disk.disabled)
        _policies = disk.policies
    }

    private func persistPolicies() {
        var disk = PolicyDisk()
        disk.disabled = Array(disabledToolNames).sorted()
        disk.policies = _policies
        let url = Self.policiesFileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(disk) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// AgentDetailView lists per-agent dynamic (plugin-registered) tools
    /// and reads each entry's `.name`. Dynamic tools come from the
    /// sandbox plugin runtime which is amputated on Intel, so the list
    /// is always empty.
    struct DynamicToolRef: Sendable { let name: String }
    func listDynamicTools() -> [DynamicToolRef] { [] }

    // MARK: - ToolsManagerView surface (M11 Phase 11.B.2)

    /// A registered tool as ToolsManagerView lists it. Mirrors upstream
    /// `ToolRegistry.ToolEntry`.
    struct ToolEntry: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let description: String
        var enabled: Bool
        let parameters: JSONValue?
        /// Rough heuristic (~4 chars/token) — upstream uses
        /// ToolSpecTokenEstimator (excluded); the inline estimate is
        /// close enough for the tool-list token badge.
        var estimatedTokens: Int {
            (name.count + description.count) / 4
        }
    }

    /// Per-tool policy + permission detail, mirroring upstream
    /// `ToolRegistry.ToolPolicyInfo`.
    struct ToolPolicyInfo: Sendable {
        let isPermissioned: Bool
        let defaultPolicy: ToolPermissionPolicy
        let configuredPolicy: ToolPermissionPolicy?
        let effectivePolicy: ToolPermissionPolicy
        let requirements: [String]
        let grantsByRequirement: [String: Bool]
        let systemPermissions: [SystemPermission]
        let systemPermissionStates: [SystemPermission: Bool]
    }

    /// The tools registered on Intel — the folder tool suite once a working
    /// folder is selected (M12 Gap 3). ToolsManagerView renders the list.
    func listTools() -> [ToolEntry] {
        toolsByName.values
            .sorted { $0.name < $1.name }
            .map {
                ToolEntry(
                    name: $0.name,
                    description: $0.description,
                    enabled: !disabledToolNames.contains($0.name),
                    parameters: $0.parameters
                )
            }
    }

    /// Toggle a tool on/off globally. Disabled tools are dropped from
    /// `openAISpecs()` (the model never sees them). Republishes so the Tools
    /// tab + capability picker reflect the change.
    func setEnabled(_ enabled: Bool, for name: String) {
        let changed: Bool
        if enabled {
            changed = disabledToolNames.remove(name) != nil
        } else {
            changed = disabledToolNames.insert(name).inserted
        }
        guard changed else { return }
        objectWillChange.send()
        persistPolicies()
        NotificationCenter.default.post(name: .toolsListChanged, object: nil)
    }

    /// Policy detail for a tool. Returns a default-`.auto` policy with
    /// no permission requirements on Intel (sandbox-gated tools are
    /// amputated).
    func policyInfo(for name: String) -> ToolPolicyInfo? {
        ToolPolicyInfo(
            isPermissioned: false,
            defaultPolicy: .auto,
            configuredPolicy: _policies[name],
            effectivePolicy: _policies[name] ?? .auto,
            requirements: [],
            grantsByRequirement: [:],
            systemPermissions: [],
            systemPermissionStates: [:]
        )
    }

    /// Register/unregister sandbox plugin tools. Sandbox runtime is
    /// amputated on Intel, so these are no-ops.
    func registerSandboxPluginTools(plugin: SandboxPlugin) {}
    func unregisterSandboxPluginTools(pluginId: String) {}
}

// MARK: - MemoryService
//
// The real Intel distillation orchestrator (buffer → debounce → one-call
// distill via CloudChatEngine → episode + pinned + identity) lives in
// `IntelMemoryService.swift`. The old no-op `bufferTurn` stub that used to sit
// here was removed in Phase 2.

// MARK: - GenerativeGreeting (no-op on Intel)

final class GenerativeGreetingPool: @unchecked Sendable {
    static let shared = GenerativeGreetingPool()
    func setActive(agent: Agent, model: String) async {}
    func popFresh(for agent: Agent, model: String) async -> GenerativeGreeting? { nil }
    func seed(_ cached: GenerativeGreeting, for agent: Agent, model: String) async {}
    func warmUp(for agent: Agent, model: String) async {}
}

final class GenerativeGreetingService: @unchecked Sendable {
    static let shared = GenerativeGreetingService()
    func generate(agent: Agent, fallbackModel: String) async throws -> GenerativeGreeting { throw CancellationError() }

    /// Used by `ConfigurationView`'s greeting persona row
    /// (un-body-swapped in M11 Phase 11.A.3.1) as placeholder text
    /// when the user hasn't set a custom persona. The actual
    /// greeting generation is amputated on Intel; this string is
    /// purely for the UI's empty-state hint.
    static let defaultPersonaInstruction: String = "Be warm and playful. Keep it short."
}

// MARK: - SharedArtifact (stub)

enum ArtifactContextType: String, Sendable {
    case work
    case chat
}

struct ProcessingResult: Sendable {
    let enrichedToolResult: String
}

struct SharedArtifact: Identifiable, Sendable, Equatable {
    let id: String
    let contextId: String
    let contextType: ArtifactContextType
    let filename: String
    let mimeType: String
    let fileSize: Int
    let hostPath: String
    let isDirectory: Bool
    let content: String?
    let description: String?
    let isFinalResult: Bool
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        contextId: String,
        contextType: ArtifactContextType,
        filename: String,
        mimeType: String,
        fileSize: Int,
        hostPath: String,
        isDirectory: Bool = false,
        content: String? = nil,
        description: String? = nil,
        isFinalResult: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.contextId = contextId
        self.contextType = contextType
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.hostPath = hostPath
        self.isDirectory = isDirectory
        self.content = content
        self.description = description
        self.isFinalResult = isFinalResult
        self.createdAt = createdAt
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isText: Bool { mimeType.hasPrefix("text/") || mimeType == "application/json" }
    var isHTML: Bool { mimeType == "text/html" }
    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isPDF: Bool { mimeType == "application/pdf" }
    var categoryLabel: String {
        if isDirectory { return "Directory" }
        if isImage { return "Image" }
        if isPDF { return "PDF" }
        if isAudio { return "Audio" }
        if isVideo { return "Video" }
        if isHTML { return "Web Page" }
        if isText { return "Text" }
        return "File"
    }

    enum ResolutionFailure: Error {
        case markersMissing
        case noContentOrPath
        case destinationRejected(filename: String)
        case pathRejected(path: String)
        case fileNotFound(path: String, searchedLocations: [String])
        case copyFailed(source: String, detail: String)
    }

    static func fromEnrichedToolResult(_ resultText: String) -> Any? { nil }

    static func processToolResultDetailed(
        _ text: String,
        contextId: String,
        contextType: ArtifactContextType,
        executionMode: ExecutionMode,
        sandboxAgentName: String? = nil
    ) -> Result<ProcessingResult, ResolutionFailure> {
        .success(ProcessingResult(enrichedToolResult: text))
    }
}

// MARK: - Data + SHA256

private extension Data {
    func sha256() -> String {
        SHA256.hash(data: self).compactMap { String(format: "%02x", $0) }.joined()
    }
}

#endif
