# Intel Fork — Archeology Report

**Date:** 2026-05-23  
**Build:** `swift build --arch x86_64` — **succeeds** with 293 surviving files, 321 excluded.  
**Method:** Iterative `exclude:`-driven dependency-cone mapping in `Packages/OsaurusCore/Package.swift`.

## Findings

The four amputated subsystems — MLX (vmlx-swift), FluidAudio, Containerization, and VecturaKit — form a dependency cone that pulls **55.8% of OsaurusCore** (321 of 575 source files) into exclusion. This is roughly 7× the original plan's estimate of 3–5 rebase-conflict files. The cone reaches into virtually every subsystem: `AppDelegate`, `HTTPHandler`, `ChatEngine`, `Router`, `AgentLoopTools`, the entire memory/search stack, all sandbox infrastructure, all voice, and all server-settings UI. Even cloud-only API paths (Anthropic, OpenAI, Gemini) cannot survive without the excluded files because the chat engine and HTTP handler reference MLX runtime types, embedding services, and search indexes backed by VecturaKit.

## What Survived (293 files)

- **Identity** (18 files): MasterKey, DeviceKey, AgentKey, RecoveryManager, PairingKey, iCloud Keychain integration — fully intact.
- **Networking core** (5 files): `OsaurusServer`, `RelayTunnelManager`, HTTP protocol helpers — the NIO lifecycle survives.
- **Generic UI** (`Views/Common/`, `Views/Settings/ServerSettings/` non-MLX sections) — shared components, theme infrastructure, proxy/advanced-HTTP config.
- **Model-agnostic runtime** (14 `Services/ModelRuntime/` files): MetalGate, format adapters, capability detection — pieces decoupled from MLX's batch engine.
- **Documents** (15 files): The document pipeline and format registry are untouched.

## The Rewrite Surface

To make the Intel fork runnable, each excluded file needs one of:
- **Inline `#if OSAURUS_INTEL` stubs** (Pattern B from the plan) — keeping type declarations, providing no-op implementations for Intel.
- **Architecture refactors** to decouple core types (e.g., `ServerController`, `ModelRuntime`, search services) from their MLX/VecturaKit dependencies.
- **Acceptance of graceful degradation**: chat without local models, embeddings via renee-rag plugin, no sandbox, no voice.

The 321-file exclude list in `Package.swift` serves as the authoritative map of the dependency cone. Incremental rewrites should target files in order of criticality: `AppDelegate` → `HTTPHandler` → `ChatEngine` → `Router` → `AgentLoopTools` → search services → UI.

## Conclusion

The amputation is architecturally correct — the four subsystems ARE the only Apple-Silicon-only dependencies — but OsaurusCore's monorepo structure creates a shallow, wide type graph where core infrastructure transitively references subsystem-specific types through internal visibility (no `public` needed — every type is visible module-wide). The plan's surgical approach underestimated this graph depth by an order of magnitude. Future ports should either (a) adopt in-module stub packages (proven viable — `Packages/IntelStubs/` resolves all `import`-level errors) paired with selective body-wrapping, or (b) isolate the four subsystems into true SwiftPM library targets so the dependency edges are explicit and amputation becomes library-level removal rather than file-level exclude cascading.

## M9 Plugin Capability Testing (2026-05-23)

**Status:** Phase 1–3 committed, Phase 4 test manifests created, Phase 5 (docs) pending.

### Test Setup

Two test plugin manifests installed in `~/.osaurus/Tools/`:

- `com.test.hello` — requires `["http"]` (Intel-compatible) → expected: **compatible**
- `com.test.needs-mlx` — requires `["mlx_inference", "vector_storage"]` → expected: **incompatible** (Apple Silicon required)

### Intel Host Capabilities

```
http, sqlite, config, logging, dispatch, file_io
```

### Expected PluginManager Behavior (Phase 2 implementation)

| Plugin | host_capabilities_required | Intel Compatibility | Bucket |
|---|---|---|---|
| `com.test.hello` | `["http"]` | `http` is supported | Compatible |
| `com.test.needs-mlx` | `["mlx_inference", "vector_storage"]` | Both missing | Apple Silicon Required |

### Verification

- `swift build --arch x86_64` — passes
- `xcodebuild` — BUILD SUCCEEDED
- `PluginCompatibilityChecker.check(required: ["http"])` → `.compatible`
- `PluginCompatibilityChecker.check(required: ["mlx_inference", "vector_storage"])` → `.incompatible`
- `PluginCompatibilityChecker.check(required: nil, optional: ["mlx_inference"])` → `.degraded`
- Empty requirements (nil) → `.compatible` (backwards compat)

Full end-to-end dylib loading + tool invocation testing is deferred until the full PluginManager C ABI is restored on Intel (requires `ExternalTool`, `PluginHostContext`, etc. — Wave D-level work).

---

## M19 — ChatGPT/Codex OAuth reached the real protocol (2026-09-08)

OAuth login and live model discovery could succeed while every generated turn
failed. The Intel `CloudChatEngine` was posting a Chat Completions `messages`
body to `/backend-api/codex/responses` and parsing only `choices[].delta`. The
endpoint and headers were finally right; the wire language was not.

Intel now has a focused Responses bridge: request conversion, typed SSE parsing,
explicit failed/incomplete-stream errors, tool calls, and encrypted-reasoning
replay across tool rounds. A shared credential actor refreshes expired OAuth
tokens once for concurrent discovery/Test/inference callers. Provider Test uses
the saved provider id and the live catalog, so static fallback models can no
longer turn a broken sign-in into a green result. Ordinary OpenAI-compatible and
DeepSeek paths remain on Chat Completions.

The decisive lesson is familiar by now: a compiled UI and a successful OAuth
callback prove only that the front door opens. On Rosy, we follow the request all
the way to its terminal stream event. See `docs/INTEL_CODEX_OAUTH.md` for the wire
contract and verification boundary.

---

## Marathon Session 2026-05-23 → 2026-05-24

**Agent:** Sunny (DeepSeek-V4-Pro via OpenCode)  
**Branch:** `intel-fork`  
**Remote:** `origin https://github.com/reneezmp/osaurus.git`

### What was built (M2 through M10 partial)

This session transformed the Intel fork from a 293-file "compiles but doesn't run" substrate into a native Intel .app with: HTTP+MCP+agent loop (M2-M6), 126 view files restored with Apple Silicon Only placeholders (M6.5+M8a Waves A-D), capability-aware plugin loading as a real upstream-worthy feature (M9), and a protocol+conformer architecture for ChatView (M10 Phases 1-4d, Waves 2-7, Auto-Sync Waves 1-2). The .app launches, streams from DeepSeek via cloud proxy, serves MCP tools, and has functional PluginManager + PluginsView. ChatView is un-body-swapped and compiling to 289 errors (down from 32,157 at start) but stuck at a Nash equilibrium where each stub API fix trades errors rather than reducing them.

**Strategic docs in the vault** (read these in order if you're the M10.5 agent):
1. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_M10_AutoSync.md` — **the M10.5 execution plan**, written after this session ended. Read FIRST. Contains the source-of-truth-reading strategy, phase-by-phase paste-prompts, forbidden/required patterns, and the Agent Logging Protocol (you append your work history to dedicated sections in that doc as you execute).
2. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_Fork_PathB.md` — the broader project map across M1-M10.5. Has the progress update section that summarizes this entire marathon.
3. `/Users/renee/Library/Mobile Documents/iCloud~md~obsidian/Documents/Renee/02_Projects/Osaurus_Intel_Plugin_Capability_Loading.md` — M9's design doc (capability-aware plugin loading). Useful background; not strictly required for M10.5.

### File organization map

**M10 Core files:**

| File | Lines | Description |
|---|---|---|
| `Services/Chat/CloudChatEngine.swift` | 147 | Cloud-backed `ChatEngine` actor conforming to `ChatEngineProtocol`. Uses `DEEPSEEK_API_KEY` env var. Streaming via `URLSession.shared.bytes(for:)`, non-streaming via `data(for:)`. Wrapped in `#if OSAURUS_INTEL`. |
| `Managers/Chat/ChatWindowManager.swift` | 975 | Body-swapped. Original Apple Silicon code in `#if !OSAURUS_INTEL`. Intel `#else` block provides minimal `ChatWindowManager` that creates real `NSWindow` instances, manages window lifecycle (create, close, focus, stopAll). |
| `Managers/Chat/ChatWindowState.swift` | 546 | Body-swapped. Intel `#else` block provides `@Published` ObservableObject matching the original's properties (agentId, theme, filteredSessions, discoveredAgents, selectedDiscoveredAgent, etc.). |
| `Models/Chat/Protocols/` | 476 total across 19 files | See protocol list below. |
| `Models/Chat/IntelConformers/` | 626 total across 3 files | See conformer list below. |

**M10 Protocols** (`Models/Chat/Protocols/`):

| File | What it covers |
|---|---|
| `ChatTurnProtocol.swift` | `ChatTurn` — role, content, tool calls, timing, attachments, thinking. ~42 lines. |
| `AttachmentProtocol.swift` | `Attachment` — file metadata, audio/video loading. |
| `ModelPickerItemProtocol.swift` | `ModelPickerItem` + `ModelPickerSource` enum. Source is `enum ModelPickerSource: Sendable { case builtIn; case remote(String, String); case foundation }`. |
| `AgentManagerProtocol.swift` | `AgentManager` + `AgentInfoProtocol` — agent lookup, model selection, temperature, tokens. |
| `SpeechServiceProtocol.swift` | `SpeechService` — isRecording, stop/cancel. |
| `ChatWindowManagerProtocol.swift` | `ChatWindowManager` — window lifecycle, model names. |
| `ModelPickerItemCacheProtocol.swift` | `ModelPickerItemCache` — isLoaded, items, buildModelPickerItems. |
| `RemoteProviderManagerProtocol.swift` | `RemoteProviderManager` + `RemoteProviderConfigInfoProtocol` + `RemoteProviderInfoProtocol`. |
| `ToolRegistryProtocol.swift` | `ToolRegistry` — resolveExecutionMode, execute. |
| `ChatSessionDataProtocol.swift` | `ChatSessionData` — id, title, dates, agentId, source, turns, generateTitle. |
| `ChatSessionsManagerProtocol.swift` | `ChatSessionsManager` — save, delete, rename, setArchived. |
| `MemoryServiceProtocol.swift` | `MemoryService` — bufferTurn. |
| `ChatConfigurationProtocol.swift` | `ChatConfiguration` — disableTools, maxToolAttempts, load. |
| `GenerativeGreetingProtocols.swift` | `GenerativeGreetingPool` + `GenerativeGreetingService`. |
| `SharedArtifactProtocol.swift` | `SharedArtifact` — processToolResult, fromEnrichedToolResult. |
| `PluginManagerProtocol.swift` | `PluginManager` — notifyArtifactHandlers. |
| `ContentBlockProtocol.swift` | `ContentBlock` — id only (minimal protocol, real type is richer). |
| `ModelOptionValueProtocol.swift` | `ModelOptionValue` — boolValue. |
| `ChatTurnDataProtocol.swift` | `ChatTurnData` — init(from:). |
| `ProtocolConformances.swift` | Apple Silicon conformances (`#if !OSAURUS_INTEL`). Extends excluded concrete types to conform to M10 protocols. 102 lines. |

**M10 Intel Conformers** (`Models/Chat/IntelConformers/`):

| File | Types defined | Lines |
|---|---|---|
| `IntelDataConformers.swift` | `IntelChatTurn`, `IntelAttachment`, `IntelContentBlock` + `ContentBlockKind` enum, `IntelModelOptionValue`, `IntelChatTurnData`, `IntelModelPickerItem`, `DiscoveredAgent`, `PairedRelayAgent`, `BlockMemoizer`, `ToolCallDone`, `StreamingToolHint`, `StreamingDeltaProcessor`, `StreamingReasoningHint`, `ContextBreakdown`, `ContextBudgetTracker`, `PromptQueue`, `SharedArtifactStub`, and ~40 additional stub types | 355 |
| `IntelManagerConformers.swift` | `IntelAgentManager` + `AgentInfo` type, `IntelModelPickerItemCache`, `IntelChatSessionData`, `IntelChatSessionsManager`, `IntelChatConfiguration` | 171 |
| `IntelStubConformers.swift` | `IntelSpeechService`, `IntelRemoteProviderManager` + `Provider` + `ProviderAuthType`, `IntelToolRegistry`, `IntelMemoryService`, `IntelGreetingPool`, `IntelGreetingService`, `IntelSharedArtifact` | 100 |

**Current typealiases** (in the respective conformer files):

```
ChatTurn = IntelChatTurn
Attachment = IntelAttachment
ContentBlock = IntelContentBlock
ModelOptionValue = IntelModelOptionValue
ChatTurnData = IntelChatTurnData
ModelPickerItem = IntelModelPickerItem
AgentManager = IntelAgentManager
ModelPickerItemCache = IntelModelPickerItemCache
ChatSessionData = IntelChatSessionData
ChatSessionsManager = IntelChatSessionsManager
ChatConfiguration = IntelChatConfiguration
SpeechService = IntelSpeechService
RemoteProviderManager = IntelRemoteProviderManager
RemoteProvider = IntelRemoteProviderManager.Provider
ToolRegistry = IntelToolRegistry
MemoryService = IntelMemoryService
GenerativeGreetingPool = IntelGreetingPool
GenerativeGreetingService = IntelGreetingService
SharedArtifact = IntelSharedArtifact
```

**Other key files:**

| File | Lines | Description |
|---|---|---|
| `Networking/MCPBridge.swift` | 213 | MCP server with stateless HTTP transport, 3 demo tools. |
| `Plugin/HostCapability.swift` | 63 | 12-capability enum + `OsaurusHostCapabilities.supported` registry. |
| `Plugin/PluginCompatibility.swift` | 48 | `PluginCompatibilityChecker` — compatible/incompatible/degraded. |
| `Views/Common/AppleSiliconOnlyOverlay.swift` | 82 | Reusable overlay + `.appleSiliconOnly()` ViewModifier. |
| `Views/Common/AppleSiliconOnlyTab.swift` | 54 | Full-tab placeholder for Apple Silicon sections. |
| `Utils/OsaurusBuild.swift` | 14 | `OsaurusBuild.isIntel` flag. |
| `Managers/Plugin/PluginManager.swift` | 1562 | Body-swapped. Intel `#else` block scans `~/.osaurus/Tools/` for `manifest.json`, checks capabilities via `PluginCompatibilityChecker`, populates loadedPlugins/incompatiblePlugins/degradedPlugins. |
| `Views/Plugin/PluginsView.swift` | ~1800 | Three-bucket UI on Intel (Compatible / Degraded / Apple Silicon Required). |
| `Networking/HTTPHandler.swift` | ~500 | Cloud proxy + agent loop for `/v1/chat/completions` and `/v1/models`. Defines `ChatCompletionRequest`, `ChatMessage`, `ToolCall`, `ChatCompletionChunk`, etc. |
| `Views/Settings/ServerSettingsTabContent.swift` | ~260 | Body-swapped. Intel shows `AppleSiliconOnlyTab`. |

### Conformer → original source map (gift to M10.5 Phase 0)

| Intel-lite type | File | Original excluded source | Notes |
|---|---|---|---|
| `IntelChatTurn` | IntelDataConformers.swift | `Models/Chat/ChatTurn.swift` | 60+ call site usage. Uses `MessageRole` (from `InternalMessage.swift`, NOT excluded). Has `Equatable` with manual `==`. Attachments are `[IntelAttachment]`. |
| `IntelAttachment` | IntelDataConformers.swift | `Models/Chat/Attachment.swift` | Equatable. Computed properties for file metadata. |
| `IntelContentBlock` | IntelDataConformers.swift | `Models/Chat/ContentBlock.swift` | Has `ContentBlockKind` enum with associated values: `.sharedArtifact(Any)`, `.userMessage(String, Any?)`, `.assistantMessage(String)`, `.thinking(String)`, `.toolCall(String, String)`. |
| `IntelChatTurnData` | IntelDataConformers.swift | `Models/Chat/ChatTurnData.swift` | Conforms to both `ChatTurnProtocol` and `ChatTurnDataProtocol`. Has `Equatable`. |
| `IntelModelPickerItem` | IntelDataConformers.swift | `Models/Configuration/ModelPickerItem.swift` | Uses `ModelPickerSource` enum (from Protocol file). Source is `.remote(String, String)` with unnamed associated values. |
| `IntelAgentManager` | IntelManagerConformers.swift | `Managers/AgentManager.swift` | Over 1,000 lines original. Intel stub has `agent(for:)`, `effectiveModel(for:)`, `effectiveMemoryDisabled(for:)`, `effectiveTemperature(for:)`, etc. |
| `IntelModelPickerItemCache` | IntelManagerConformers.swift | `Managers/Model/ModelPickerItemCache.swift` | Original ~150 lines. Intel stub returns cloud models only. |
| `IntelChatSessionData` | IntelManagerConformers.swift | `Models/Chat/ChatSessionData.swift` | Has `generateTitle(from:)` static method. `turns: [IntelChatTurnData]`. `source: SessionSource` (local enum). |
| `IntelSpeechService` | IntelStubConformers.swift | `Managers/SpeechService.swift` | No-op. All methods are stubs. |
| `IntelRemoteProviderManager` | IntelStubConformers.swift | `Managers/RemoteProviderManager.swift` | Has nested `Provider` type with `authType: ProviderAuthType` enum (`.apiKey`, `.bearerToken`, `.oauth`). `updateProvider(_:apiKey:)` method. |
| `IntelToolRegistry` | IntelStubConformers.swift | `Tools/ToolRegistry.swift` | `execute(name:argumentsJSON:)` → returns `"ok"`. |
| `IntelGreetingPool` | IntelStubConformers.swift | `Services/Chat/GenerativeGreetingPool.swift` | No-op — all methods return nil/do nothing. |
| `IntelSharedArtifact` | IntelStubConformers.swift | `Models/Chat/SharedArtifact.swift` | Has nested `ResolutionFailure` enum: `.markersMissing`, `.noContentOrPath`, `.destinationRejected(filename:)`. `processToolResultDetailed(_:contextId:contextType:executionMode:sandboxAgentName:)` where `contextId` is `String`. |
| `DiscoveredAgent` | IntelDataConformers.swift | `Models/Agent/RemoteAgentViews.swift` (unsure — verify) | ~15 computed properties. |
| `PairedRelayAgent` | IntelDataConformers.swift | Same as DiscoveredAgent (unsure) | ~12 computed properties. |
| `BlockMemoizer` | IntelDataConformers.swift | `Managers/BlockMemoizer.swift` | `blocks(from:streamingTurnId:agentName:thinkingEnabled:)` method (keyword args from ChatView). |
| `StreamingToolHint` | IntelDataConformers.swift | `Tools/AgentLoopTools.swift` (unsure) | Static methods: `decodeDone(_:)` → `ToolCallDone?`, `decode(_:)`, `decodeArgs(_:)`. |
| `StreamingDeltaProcessor` | IntelDataConformers.swift | (unsure — verify) | `init(turn:onChange:)`, `finalize()`, `receiveReasoning(_:)`, `receiveDelta(_:)`. |
| `ContextBreakdown` | IntelDataConformers.swift | (unsure — verify) | `from(turns:estimatedOutput:conversation:memory:system:instructions:)` static method. |
| `TTSService` | IntelDataConformers.swift | `Managers/TTSService.swift` | `toggleSpeak(_:messageId:voiceOverride:)`, `playingMessageId`. |
| `PromptQueue` | IntelDataConformers.swift | `Views/Chat/PromptQueue.swift` | Original is an `ObservableObject` class. Intel stub has `current`, `enqueue(_:)`, `drainAll()`, `advance()`. Originally body-swapped; Intel `#else` block removed because it collided with this stub. |
| `CloudChatEngine` | Services/Chat/CloudChatEngine.swift | `Services/Chat/ChatEngine.swift` + `ChatEngineProtocol.swift` | Provides BOTH the protocol and the actor. Only on Intel (`#if OSAURUS_INTEL`). |

### Decisions / rationale not obvious from commits

- **Strategy B for OpenAIAPI (Phase 3):** OpenAIAPI.swift defines canonical `ChatCompletionRequest`/`ChatCompletionResponse` but cascaded into `ModelOptionValue` (from excluded `ModelOptions.swift`). Re-excluded it, kept HTTPHandler's local types as canonical on Intel. Both definitions are `#if`-guarded so no collision at compile time.

- **PluginManager was body-swapped with a functional Intel block** rather than fully restoring it because the original references 10+ excluded managers (AgentManager, ExternalTool, ToolRegistry, RelayTunnelManager, SkillManager, PluginHostContext, etc.). The Intel block reads `manifest.json` directly from `~/.osaurus/Tools/` instead of dlopen-ing dylibs.

- **ChatWindowManager/ChatWindowState were body-swapped with functional Intel stubs** because the originals reference `ChatEngine`, `ChatSessionStore`, `AgentManager`, `SpeechService`, and many other excluded types. The Intel stubs provide real window creation and lifecycle.

- **All protocol files are `internal`** (no `public` keyword). They exist only to document the API surface and provide compile-time checking within the OsaurusCore module. The `#if OSAURUS_INTEL` typealiases bypass the protocols at runtime — ChatView uses concrete Intel types directly.

- **IntelChatTurn.attachments is `[IntelAttachment]`** not `[any AttachmentProtocol]` because Swift's existentials don't work well with `@Published`, `Equatable`, and array extensions. The concrete type approach was necessary for ChatView compilation.

- **ContentBlockKind enum** was created to match ChatView's pattern matching on `block.kind` (`.sharedArtifact(art)`, `.userMessage(text, _)`, etc.). Without it, dozens of pattern match errors cascade.

- **The Nash equilibrium at ~289 errors** occurs because each stub API fix that matches one ChatView call site introduces a slightly different type that doesn't match ANOTHER call site on the same type. For example, fixing `AgentManager.agent(for:)` to return `AgentInfo?` surfaced a mismatch at `ChatView.swift:942` where `Agent` doesn't conform to `AgentInfoProtocol`. The two types are compatible on Apple Silicon (where `Agent` IS `Agent`) but diverge on Intel (where `Agent` is the real `Agent` struct from `Agent.swift` but `AgentInfoProtocol` expects different members).

### The Nash equilibrium discovery

Manual stub-matching plateaus around 280-290 errors because:

1. **Error messages don't reveal byte-for-byte signature precision.** "Cannot convert value of type 'String' to expected argument type 'UUID'" tells you the types differ but not WHY. Reading the excluded source reveals the original takes `UUID`, but on Intel the calling code passes `uuidString` because type inference from an upstream `Any?` return broke the chain.

2. **Signature drift is self-reinforcing.** Fixing `MemoryContextAssembler.assembleContext` to return the right type surfaced a mismatch in `ContextBudgetManager.estimateTokens`. Each fix in one stub creates a cascading type mismatch 2-3 files downstream.

3. **Protocol conformance interacts with typealiases in unexpected ways.** When `IntelChatTurn: ChatTurnProtocol`, all protocol members must match exactly. But `ChatTurnProtocol` was extracted from reading ChatView's usage, not from the original `ChatTurn` source. The ORIGINAL `ChatTurn` has members (like `consolidateContent()`, `appendContent(_:)`) that ChatView doesn't call but the protocol requires. Adding them to the protocol fixes ChatView but adds ~5-10 new compiler warnings.

4. **The M10.5 breakthrough strategy is source-of-truth reading:** for every remaining error class, read the ORIGINAL excluded source file (e.g., `Models/Chat/ChatTurn.swift`) to get the EXACT public API surface (every method signature, property type, initializer). Then regenerate the Intel conformer to match byte-for-byte. This eliminates the guesswork that causes the equilibrium.

### Current build state verification

```
Branch: intel-fork
Remote: origin https://github.com/reneezmp/osaurus.git
Working tree: clean
Error count: 289 (all in ChatView.swift)
Last commit: 2a47b8dd "M10: 283→289 — SharedArtifactStub, voiceOverride, bufferTurn sessionId, ContextBreakdown"
```

**Last 30 commits:**
```
2a47b8dd M10: 283→289 — SharedArtifactStub, voiceOverride, bufferTurn sessionId, ContextBreakdown
a2096066 M10: 285→283 — SandboxAgentProvisioner.linuxName String signature
126199a3 M10: fixes — assembleContext, view init params, 25 missing stubs
98d45f32 M10: updates — SharedArtifact contextId, updateProvider apiKey, StreamingDeltaProcessor methods
80ae7770 M10: 277→285 — StreamingDeltaProcessor methods + RemoteProvider authType
f31b6236 M10: 277 — ContentBlockKind enum, firstChatCapable extension, Equatable fixes
e916d64a M10: 275→277 — IntelChatTurnData conforms to ChatTurnProtocol
8f70fcee M10: 281→275 — visibleContent, Equatable, TTSService, MemoryDatabase fixes
29ff9b51 M10 Fresh Start: 507→275 errors from clean base (typealiases + 30+ stubs + ChatWindowState rewrite)
9c136c52 M10 Phase 4d: Intel-lite conformers for ChatView protocol dependencies (9 managers, 6 data types)
06ae85a1 M10 Phase 4c: Apple Silicon concrete types conform to M10 protocols (#if !OSAURUS_INTEL)
f40b426f M10 Phase 4b: extracted 17 protocol files for ChatView's external dependencies
b5dab0a8 M10 Phase 3: Strategy B — OpenAIAPI re-excluded (cascaded into ModelOptionValue), HTTPHandler types kept as canonical on Intel
9648da12 M10 Phase 2: ChatWindowManager restored with Intel stubs (ChatWindowState body-swapped)
d97fde07 M10 Phase 1: CloudChatEngine class (cloud-backed M6 loop)
9a0b9370 M9 Phase 4: plugin test manifests + INTEL_ARCHEOLOGY updated with capability filtering verification
94e757bc M9 Phase 3: PluginsView with three-bucket capability UI (Compatible / Degraded / Apple Silicon Required)
228d194f M9 Phase 2: PluginManager restored with capability-aware loading (Intel #else block, original preserved)
3941ddba M9 Phase 1: capability schema + HostCapability registry + PluginCompatibilityChecker
41c6761e M8a-WaveC: 22 views + 11 ServerSettings sections restored
468f2473 M8a-WaveB: 12 views restored
dc7c23e9 M8a: 19 zero-dep views restored
25a2c000 M6.5: Voice/Sandbox/Model views restored with Apple-Silicon-Only placeholders
eb36b683 M6.5: 12 ServerSettings sections restored + labeling infrastructure
ff1b7fa8 M6.5-batch1: Labeling infrastructure + 12 ServerSettings sections restored
db7626ec M6: ChatEngine rebuilt, full agent loop with MCP tool calls works
a076aeaa M5: MCP server functional, 3 demo tools accessible via /mcp endpoint
b733cd46 M4: HTTPHandler proxies /v1/chat/completions to DeepSeek, SSE streaming works
da787ae7 M3: Router restored, HTTP server listens, all routes return stub 200
```

### Sign-off

Session closed 2026-05-24 at ~02:00 UTC-3. Working tree clean, 289 errors remaining in ChatView.swift only (down from 32,157 at start). All M2 through M10 infrastructure committed to `intel-fork` branch. ChatView is un-body-swapped with 20 typealiases and ~60 stub types active. The .app builds via xcodebuild and launches with functional cloud chat proxy + MCP server + PluginManager. M10.5 begins by reading this document and the M10.5 auto-sync strategy doc. ☀️🦕

---

## M10.5 Phase 6 — Compile Victory + Runtime Crash Discovery

**Date:** 2026-05-25  
**Tag:** `m10.5-zero-errors-runtime-crash-investigation`  
**Working tree:** Clean at `7521dd25` (themedAlert removal commit)

### Compile Reduction: 289 → 0

After 25+ commits across Phases 0-6, `swift build --arch x86_64` produces **zero errors**. The reduction trajectory:

| Phase | Technique | Outcome |
|---|---|---|
| Phase 2 | Data type fixes (class→class, enum→enum, protocols) | 289 → 193 (-96) |
| Phase 3 | Manager expansion | 193 → 193 |
| Phase 4-5 | Stub cleanup + apiKey fix | 193 → 177 (-16) |
| Phase A | Concretize existentials (IntelStubConformers, IntelManagerConformers) | 177 → ~20 |
| Phase A | FloatingInputCard 14 Any→concrete | Margin reduction |
| Phase A | Hidden errors unmasked (notification names, stub methods) | Final 1 → 0 |

**Key techniques:**
- **18 typealiases eliminated** — Intel types own original names directly
- **Phase A concretization** — All `any Protocol` existentials → concrete types matching originals byte-for-byte
- **Hidden error unmasking** — The 1 remaining type-checker timeout was masking 5 real compilation errors: missing `Notification.Name` extensions (`chatToolbarSelectDiscoveredAgent`, `chatToolbarSelectRelayAgent`, `vadStartNewSession`) and missing stub methods (`setCloseCallback`, `cleanup`, `startNewChat`, `loadSession`, `refreshSessions`, `agents` array, `Equatable` on `ModelPickerSource`)
- **Phase B extraction** — ChatSidebarSection, ChatInputSection, whatsNewContent, agentSheetContent, handleChatToolbarSelectDiscovered (~85 lines extracted from body)
- **~50 inline expression splits** (for-loops, typed locals, closure pre-computation)

**Verification:**
```
swift build --arch x86_64: 0 errors ✅
xcodebuild Release x86_64: BUILD SUCCEEDED ✅
file binary: Mach-O 64-bit executable x86_64 ✅
```

### Runtime Crash: `_swift_getGenericMetadata` Recursion

Despite zero compile errors, the `.app` crashes on launch with an identical pattern across 7 crash reports (Error1–7.md):

```
Exception Type: EXC_BAD_ACCESS (SIGSEGV) at stack guard
Recursion depth: 5,331–6,072 frames through:
  _swift_getGenericMetadata → AttributeGraph → SwiftUICore
Trigger: ChatWindowState.init() + NSHostingView/NSHostingController(rootView:)
```

**Key evidence table:**

| Test | ChatWindowState? | View | Result |
|---|---|---|---|
| Minimal OK | No | `Text("hello")` | ✅ Works |
| Error7 | Yes | `Text("hello")` | ❌ Crash |
| Error6 | Yes | `ChatView(Text("OK"))` | ❌ Crash |
| Error1–5 | Yes | `ChatView(...)` via NSHostingController/View | ❌ Crash |

**Working theory:** `ChatWindowState.init()` instantiates types (ChatSession, ThemeManager) that trigger lazy generic metadata resolution. In the `OsaurusCore` module, one of the new View structs (ChatSidebarSection, ChatInputSection) or their `some View` return types forms a circular metadata dependency. When the runtime tries to materialize these types, it recurses until stack overflow.

**Key insight:** The crash occurs even with `Text("hello")` as the rendered view. It's NOT in ChatView's body content — it's in the module-level type metadata that `ChatWindowState` references.

**NSHostingView vs NSHostingController:** `NSHostingController` triggered a different crash (AttributeGraph dependency cycle from `.themedAlert` in the original body). `NSHostingView` avoids that but the `_swift_getGenericMetadata` crash persists through both. The `NSHostingView` switch was correct but insufficient.

### Investigation Plan (in progress)

| Phase | What | Status |
|---|---|---|
| Phase 1 | Tag + document compile victory | ✅ Done |
| Phase 2 | Granular allocation tests (2A–2D): isolate which type triggers crash | ✅ Done — `ChatWindowState`, `ChatSession`, `ThemeManager` all safe |
| Phase 3 | Crash log forensics: extract exact metadata cycle type from crash trace | ✅ Done — `swift_getOpaqueTypeMetadataImpl` in `chatModeContent.getter` |
| Phase 4 | Module-scope bisection: ChatInputSection/ChatSidebarSection cycle source | ✅ Done — pairwise cycle via `@ObservedObject` in both View structs |

---

## M10.5 Phase 7 — Runtime Crash Resolved + Remaining Work

**Date:** 2026-05-25  
**Key milestone:** APP LAUNCHES WITHOUT CRASH — `ChatContentView` struct breaks opaque type metadata chain.

### Crash Resolution

After 14 consecutive runtime crashes (Error1–14), the root cause was identified:

**The `chatModeContent` computed property returned `some View` — an opaque return type.** At runtime, `swift_getOpaqueTypeMetadataImpl` tried to resolve the concrete type behind this opaque return, which triggered `chatModeContent.getter` re-evaluation, which triggered AttributeGraph updates, which re-triggered metadata resolution — infinite recursion at 11,175 levels.

**Fix:** Extract the entire `chatModeContent` body into a standalone `ChatContentView: View` struct (`Packages/OsaurusCore/Views/Chat/ChatContentView.swift`). The struct's `var body: some View` return type is resolved independently per-struct (not shared with ChatView's opaque type chain). All sub-view properties use concrete `AnyView` types instead of `some View` to prevent sub-opaque chains.

**Also fixed during Phase 7:**
- `MessageThreadView` (Intel #else block): body-swap placeholder replaced with raw `turns` display (shows user messages + assistant responses + thinking text)
- `ChatEmptyState` (Intel #else block): body-swap placeholder replaced with simple "New Chat / Type a message" text
- `FloatingInputCard` (Intel #else block): 14 `Any`-typed params concretized to original concrete types (byte-for-byte)
- Model auto-select: `session.selectedModel = "deepseek-v4-pro"` set in `.onAppear` when nil

### Current State

| Feature | Status |
|---|---|
| `swift build --arch x86_64` | ✅ 0 errors |
| `xcodebuild Release x86_64` | ✅ BUILD SUCCEEDED |
| Binary type | ✅ Mach-O 64-bit executable x86_64 |
| App launch + window | ✅ Opens without crash |
| Sidebar | ✅ ChatSessionSidebar renders (body-swapped placeholder) |
| Chat input bar | ✅ Intel-native HStack: TextField + send/stop buttons |
| Model auto-select | ✅ "deepseek-v4-pro" set on launch |
| User messages display | ✅ "You: <text>" appears in message area after send |
| Assistant responses | ❌ NOT appearing — streaming starts (green dot) but no response text added to `turns` |

### Root Cause of Missing Responses

The chat engine runs (send→stop→send toggle proves streaming lifecycle), but assistant turns are not saved to `observedSession.turns`. Likely causes:
1. `CloudChatEngine` missing `DEEPSEEK_API_KEY` environment variable
2. `CloudChatEngine` HTTP request failing silently
3. Response parsing failing to create `ChatTurn` objects

### Next Session Plan

1. **Check CloudChatEngine API key:** Verify `DEEPSEEK_API_KEY` is set in environment or AppDelegate
2. **Add verbose logging:** Print HTTP request/response to stderr from CloudChatEngine
3. **Test with curl:** `curl localhost:1338/v1/chat/completions` with a test message to verify cloud proxy works independently
4. **If cloud proxy works but chat doesn't:** Debug the `ChatEngine` → `ChatSession` turn storage pipeline
5. **If cloud proxy fails:** Fix the HTTP handler or API key configuration
6. **Once responses appear:** Refine message thread rendering (real message bubbles, markdown, streaming)

### Git State

- Branch: `intel-fork`
- Tag: `m10.5-zero-errors-runtime-crash-investigation`
- Latest commit for Phase 7 resolution: `709f4671` — "ChatContentView struct extracts entire chatModeContent body — NO RUNTIME CRASH!"
- Uncommitted changes: ChatContentView.swift, ChatEmptyState.swift, MessageThreadView.swift (diagnostic UI improvements)
- Working tree clean after doc update commit

---

## M10.5 Phase 8 — Real Osaurus Chat UI Restored on Intel (CLOSURE)

**Date:** 2026-05-30
**Key milestone:** APP RENDERS THE UPSTREAM OSAURUS CHAT EXPERIENCE on Intel — markdown bubbles, hero greeting, rich sidebar with filters/badges, FloatingInputCard with attachments + model picker + reasoning effort + context budget, streaming DeepSeek responses with proper Thinking panel for reasoning models.

### Tag

`m10.5-phase-8-complete`

### Where we started Phase 8

Phase 7 left us with: zero compile errors, app launches, MCP / HTTP / cloud proxy all working — but the chat surface was **diagnostic-quality**:
- `MessageThreadView` Intel branch enumerated turns as `Text("You: ...") + Text("Assistant: ...")`
- `ChatSessionSidebar` was a 94-line Intel stub with "Chats / Search / row" structure but no filters, badges, or actions
- `ChatEmptyState` was a 27-line stub showing "New Chat / Type a message below to start"
- `FloatingInputCard` was a 32-line `AppleSiliconOnlyTab` placeholder
- `ChatContentView` rendered an inline diagnostic `HStack { TextField + Send/Stop }` instead of the real input

Renée explicitly reframed the goal: **transpose the upstream Osaurus UI, do NOT recreate it.** The Phase 7 diagnostic UI was scaffolding to verify the streaming pipeline; Phase 8's job was to peel it off and surface the original code that was already in the repo behind `#if !OSAURUS_INTEL` guards.

### The five techniques Phase 8 codified

**1. Un-body-swap with selective gating.** For each body-swapped file, the upstream branch is read in full; types it references are checked against the Intel conformer surface (`Packages/OsaurusCore/Models/Chat/IntelConformers/`); the outer `#if !OSAURUS_INTEL` guard is removed; truly amputated sub-features (MLX local-model rows, voice mic + transcription, sandbox tool-registrar UI, slash-command popup contents, skill chip wiring, export coordinator) get **narrow** `#if !OSAURUS_INTEL` gates inside the upstream code instead of swallowing the whole file.

**2. Un-exclude > stub (when the file is mostly pure-Foundation).** Several upstream files turned out to have only one or two Apple-Silicon-only references in otherwise-portable code. Rather than mirror their 500+ lines in conformer files (which would drift from upstream every release), we **removed them from `Package.swift`'s exclude list** and surgically gated the small Apple-Silicon edges. Examples:
- `Models/Chat/Attachment.swift` (525 LOC) — had four `try? AttachmentBlobStore.read(hash)` references in spillover hydration paths; added an `enum AttachmentBlobStore { static func read(_:) throws -> Data }` Intel stub that throws.
- `Models/Configuration/ModelOptions.swift` (709 LOC) — fully Foundation, un-excluded as-is.
- `Models/Configuration/ModelPickerItem.swift` (375 LOC) — gated `static func fromMLXModel(_:)` only.
- `Services/ModelOptionsStore.swift`, `Utils/DocumentParser.swift`, `Services/Context/ClipboardService.swift`, `Managers/ToastManager.swift` (+ its `Localized` extension), `Models/Configuration/ModelInfo.swift` — all un-excluded with 1-3 line stub additions for the helpers they reached into.

Result: ~3,000 lines of upstream surface restored to Intel without mirroring a single line of it in the conformer files.

**3. The sentinel pattern for cross-architecture stream wiring.** DeepSeek's reasoner endpoint emits reasoning content on a separate `reasoning_content` field in SSE chunks. Upstream `RemoteProviderService` wraps these with `StreamingReasoningHint.encode(_:)` (a `\u{FFFE}reasoning:` prefix), and `ChatView`'s delta loop calls `StreamingReasoningHint.decode(_:)` to peel the prefix and route the text to `ChatTurn.thinking`. The Intel `StreamingReasoningHint` stub used to be a no-op (`encode` returned the input unchanged, `decode` always returned `nil`), so reasoning chunks were silently dropped. Restoring the exact `\u{FFFE}reasoning:` sentinel in the Intel conformer + having `CloudChatEngine` emit `StreamingReasoningHint.encode(reasoning_content_chunk)` made the Think panel work without touching the upstream decode site. **This sentinel pattern generalizes**: any cross-architecture out-of-band signal (reasoning hints, stats hints, tool hints) can be made to compile-time-share between Apple Silicon and Intel by mirroring the same sentinel format in the Intel conformer.

**4. Inner-gate before outer-gate removal.** When un-body-swapping a file that needs selective amputation (e.g., `NativeToolCallGroupView` with its `TerminalDisplayView.Mode` references in shell-tool rendering), we applied the inner `#if !OSAURUS_INTEL` gates around the amputated regions BEFORE removing the outer `#if !OSAURUS_INTEL ... #else ... #endif` body-swap. The inner gates were no-ops while the outer body-swap was still in place (the whole branch was gated out anyway), and they became live the moment the outer body-swap was removed. This let us build-verify after each commit without ever leaving the working tree in a broken state.

**5. Conformer surface extension via call-site reading, not API guessing.** The Intel conformers built during M10.5 phases 1-6 covered just enough surface to satisfy ChatView's existing Intel branches. Restoring the upstream code lit up dozens of new surface gaps (`Attachment.Kind` enum cases, `ModelOptionValue.bool` case, `ModelPickerSource.local`, `ContextDisableInfo.disabledTools/contextLength`, `LiveVoiceAudioInputRegistry.store(snapshot:for:)`, `ModelRuntime.preencodeLiveVoiceAudioIfResident(_:)`, etc.). For each gap we read the upstream call site (which the compiler now points at directly with `error: 'X' has no member 'Y'`) and added the minimum surface needed — no speculative methods, no `Any` placeholders, no broad enum cases. When the call site needed Combine publishers (`AgentManager.$activeAgentId`, `SandboxManager.State.$status`), the conformer property was upgraded to `@Published` and the class to `ObservableObject` rather than papered over.

### Phase 8 sub-phase log

| Phase | What | Commit | Notes |
|---|---|---|---|
| 8A | Conformer scaffolding for the 10-file rendering cascade + the keystone un-body-swap | `58ffc575`, `1bcb9d90`, `416bd4fa`, `bdff2a25`, `653cbbf4` | 4 audit-build cycles + atomic 10-file un-body-swap (`MessageThreadView` ← `MessageTableRepresentable` ← `NativeMessageCellView` ← `NativeArtifactCardView` / `NativeMarkdownView` / `NativeThinkingView` / `NativeBlockViews` / `NativeToolCallGroupView` ← `MarkdownMessageView` ← `SelectableTextView`). Three corrupt `init(_ args: Any...) {}` "type-checker pacifier" inits from prior phases were found via grep and removed. |
| 8A bug 1 | Implement `BlockMemoizer.blocks(from:)` (the Intel stub returned `[]` always — `VisibleBlocksStore.blocks` was permanently empty so `MessageThreadView` rendered a blank area even though the stream was flowing) | `8759d968` | Faithful upstream mirror: per-turn header + thinking + user-message + assistant `.paragraph` blocks, `streamingTurnId` drives `isStreaming: true` for the active turn. **New audit category captured**: stub bodies that compile but produce nothing. Previous audit cycles only checked type surfaces, not function bodies. |
| 8E mini | Wire `messageThread` closure in `ChatContentView` (the closure was passed but the body still rendered inline `Text("You: ...")` diagnostic) | `50455a71` | After this commit + 8A bug 1 fix, the message thread rendered through the upstream `MessageThreadView` → `MessageTableRepresentable` → `NativeMessageCellView` pipeline for the first time on Intel. |
| 8B | Restore upstream `ChatEmptyState` with hero avatar + animated greeting + quick actions | `a1e1e5f6` | Selectively gated only the `ChatEmptyStateNoModels` sub-section (170 LOC depending on excluded `ModelManager`); restructured `if hasModels / else` so Intel always renders `readyState` (cloud chat works without local models). Found a 3rd corrupt variadic `init(_ args: Any...)` at `ChatEmptyState` L121 and removed. Added a 3-line `agentColorFor` Intel-only helper because `AgentsView` is still body-swapped. |
| 8D core | Fix Bug 2 (sessions only appeared after clicking New Chat) + Bug 3 (clicking session didn't load) | `c8887515` | Intel `ChatSessionsManager.sessions` lacked `@Published`, so `ChatWindowState.observeSessionsManager()`'s `$sessions` Combine subscription got zero events. Adding `ObservableObject` + `@Published` + rewriting nested-property mutations to copy-modify-assign (subscript struct mutation doesn't republish a dict) fixed Bug 2. ChatContentView wasn't passing `onSelect:` to `ChatSessionSidebar` so the default `{ _ in }` swallowed clicks; wiring `onSelect: { data in windowState.loadSession(data) }` fixed Bug 3. |
| 8E quick + 8D full | Drop the Phase 7 "● Streaming…/Idle Model:" diagnostic chrome + un-body-swap the upstream rich `ChatSessionSidebar` (~870 LOC) with filters/badges/search/rename popover/delete confirmation | `4c543655` | Replaced `SessionCapability` no-op struct with the upstream 4-case enum (vision/voice/code/search) + Hashable + CaseIterable + iconName + label. Removed `.dispatch` from Intel `SessionSource` (Intel-only case, not in upstream). Added `PluginDisplayNameResolver` Intel stub. Changed `ChatSessionData.capabilities` from `Any?` to `Set<SessionCapability>`. Selective gates for the export pipeline (`ChatSessionExportCoordinator` + `ExportChooserSheet`'s upstream branch both live in excluded files). |
| 8C prep 1 | Un-exclude upstream `Attachment.swift` + add `AttachmentBlobStore` Intel stub | `1947c7d3` | First application of the "un-exclude > stub" principle. ~525 LOC of upstream Attachment surface (full `Kind` enum, Codable, hydration helpers) restored to Intel with one 11-line throw-only stub. |
| 8C prep 2 | Un-exclude `ModelOptions.swift`, `ModelPickerItem.swift`, `ModelOptionsStore.swift`, `ToastManager.swift` (+ Localized), `DocumentParser.swift`, `ClipboardService.swift`, `ModelInfo.swift`; remove the now-redundant Intel stubs | `db4f04d5` | ~107 net Intel-side lines added vs ~600 lines of upstream code now compiling directly. `ModelPickerItemCache` reworked to use `.remote(providerName:"DeepSeek", providerId: stableUUID)` for the built-in deepseek models (the bespoke `.builtIn` source doesn't exist on upstream); `ModelPickerItem.Source.remoteProviderId` Intel-side extension added for the `ChatView` `item.source.remoteProviderId == providerId` filter shortcut. |
| 8C main | Un-body-swap `FloatingInputCard.swift` (4,209 LOC) with ~12 selective gates + Speech/Voice/Slash/Sandbox/Model surface extensions across Intel conformers + `SlashCommandPopup` un-body-swap (corrupt `init(_ args: Any...)` removed) + `PastedContentSheet` + `DocumentChip` un-body-swap + minimal Intel `ModelPickerView` stub (the upstream rich picker cascades into the body-swapped `ModelPickerTableRepresentable`) | (uncommitted; folded into `c9fdcc39` + later polish) | Extracted three voice/lifecycle handler `ViewModifier` structs (`BodyLifecycleHandlers`, `SpeechObservers`, `VoiceInputStateOnChange`) and four helper methods to break Swift 6.3's per-expression type-checker on the body's chained `.onChange`/`.onReceive` modifiers ("unable to type-check this expression in reasonable time"). Same `@ViewBuilder` extraction pattern applied to `inlinePendingAttachmentsPreview` switch-in-ForEach. |
| 8C wire | Route FloatingInputCard's `onSend` text directly to `ChatSession.send(_:attachments:)` | `c9fdcc39` | FloatingInputCard clears its `text` binding (which is `$observedSession.input`) BEFORE calling `onSend(fullMessage)`, so the previous `observedSession.sendCurrent()` closure always saw an empty input. Reading `sentText` from the onSend parameter and routing to `send(_:attachments:)` directly fixes it. |
| 8C polish 1 | Wire context-token tracker + reasoning-content channel | `38875e4c` | `estimatedContextTokens`/`estimatedContextBreakdown` plumbed from `ChatSession` to `FloatingInputCard`'s Context Budget popover; `StreamingReasoningHint` Intel stub replaced with the real `\u{FFFE}reasoning:` sentinel; `CloudChatEngine` now wraps `delta["reasoning_content"]` chunks with `StreamingReasoningHint.encode(_:)` before yielding so `ChatView` decodes them into `ChatTurn.thinking`. |
| 8C polish 2 | Respect the Reasoning Mode chip on the wire + populate the Context Budget popover | `1dc24c5e` | DSV4 reasoning translation: `instruct` (the user-visible "Default" chip pick) → DeepSeek `thinking: {type: "disabled"}`; `high`/`max` → `reasoning_effort: <verbatim>`. Intel `ContextBudgetManager.estimateTokens(for: [ChatTurn])` and `estimateOutputTokens(for:)` implemented with the `~4 chars / token` heuristic; `ContextBreakdown.from(context:conversationTokens:inputTokens:outputTokens:)` emits Conversation/Input/Output Entries (blue/cyan/purple) so the popover shows real numbers. |

### Final state at Phase 8 close

| Surface | Status |
|---|---|
| `swift build --arch x86_64` | ✅ 0 errors |
| `xcodebuild Release x86_64` | ✅ BUILD SUCCEEDED |
| Binary type | ✅ Mach-O 64-bit executable x86_64 |
| App launch | ✅ Opens without crash, no metadata recursion |
| Sidebar — upstream rich version | ✅ Source filters (All / Chat / Plugin / HTTP / Schedule / Watcher / Archived), capability badges, search, sticky archived divider, rename popover, delete confirmation |
| Empty state — upstream hero greeting | ✅ Hero avatar, time-of-day greeting, agent quick-action buttons, shimmer fade-in for generative greetings |
| Message rendering — upstream NSTableView pipeline | ✅ `MarkdownMessageView`/`SelectableTextView`/`NativeMessageCellView`/`MessageTableRepresentable`/`NativeBlockViews` all compile and render — proper markdown (bold, italic, headers, code blocks, lists, emojis), thinking blocks render as collapsible Disclosure-style cards, multi-paragraph spacing |
| Input bar — upstream `FloatingInputCard` | ✅ Attachments (paperclip), Slash-command trigger button (`/`), model picker chip (DeepSeek V4 Pro / Flash, popover with descriptions), Reasoning Mode chip (Default / Instruct / Reasoning / Max for DSV4), Folder picker chip, Context Budget chip with real per-rail breakdown |
| Reasoning mode on the wire | ✅ DSV4 chip → `thinking: {type:"disabled"}` (Default/Instruct) or `reasoning_effort: "high"|"max"` (Reasoning / Max). Default = no Think panel. Max = Thinking panel above answer. |
| Streaming reasoning content | ✅ `reasoning_content` SSE chunks wrapped with the `\u{FFFE}reasoning:` sentinel by `CloudChatEngine`, decoded by `ChatView`'s delta loop, routed to `ChatTurn.thinking`, surfaced as the collapsible Think panel by `BlockMemoizer.blocks(from:)`'s `.thinking` block emission. |
| Multi-turn chat persistence | ✅ Sessions appear in sidebar in real-time as turns land (Bug 2 fixed via `@Published` on Intel `ChatSessionsManager.sessions`). Click-to-load works (Bug 3 fixed via `onSelect:` wiring in `ChatContentView`). |
| Cloud model picker | ✅ Built-in `deepseek-v4-pro` + `deepseek-v4-flash` from `ModelPickerItemCache`; user can switch via the chip popover. |
| MCP server | ✅ Still running on port 1338 throughout Phase 8 — no regressions to the M5/M6 work. |

### What was NOT done in Phase 8 (deferred to M11+)

- **Settings/Management window restoration.** Multiple Settings tabs touch amputated subsystems (Models, Voice, Sandbox, SkillManager, ScheduleManager). The same un-body-swap + selective-gate technique applies but is bounded per tab. Sequencing: Themes / CloudProviders / Identity / MCP / Storage tabs first (clean restores); Agents / Plugins (mixed gating); Models / Voice / Sandbox / Skills / Schedules (likely gated out entirely or replaced with explainer panels).
- **Local model UI**. `ModelPickerTableRepresentable` stays body-swapped; the Intel `ModelPickerView` stub renders a simple SwiftUI list of options. Acceptable because Intel has no local models to manage; the picker is cloud-only.
- **Voice input**. SpeechService / SpeechModelManager / VADService / TranscriptionCleanupService / live preencode all stub-out to no-ops. The microphone button appears in FloatingInputCard but stays inert (model is not loaded, permission denied by default). When a user clicks it nothing dangerous happens.
- **Tool calls in messages**. `BlockMemoizer.blocks(from:)` doesn't emit `.toolCallGroup` blocks yet — text content of tool-using assistant turns still renders, but the per-tool cards don't. Bounded extension; lives in `IntelDataConformers.swift`.
- **Spillover attachment hydration**. `imageRef` / `documentRef` / `audioRef` / `videoRef` variants try to hydrate via `AttachmentBlobStore.read` which throws on Intel, so spilled attachments can't round-trip. Inline payloads work fine; Intel has no spillover infrastructure so this is the correct semantic.

### Lessons captured for future Intel forks

1. **The `exclude:` list is your enemy and your friend.** Big excludes look safe but cascade because Swift modules share visibility. Smaller, surgically-selected excludes (one file, gate the few Apple-Silicon edges) restore far more upstream code with less conformer maintenance.
2. **Audit type surfaces AND function bodies.** The `BlockMemoizer.blocks(from:)` no-op stub passed every type-name audit ever run but produced an empty `[ContentBlock]` array, leaving the message thread permanently blank. New audit category: "stubs whose signatures are correct but whose bodies are no-op." Grep for `{ [] }` / `{ nil }` / `{ "" }` / `{}` in conformer files when restoring upstream rendering.
3. **Body-swap "type-checker pacifier" inits leave landmines.** During M10 phases 2-7, the agent added `init(_ args: Any...) {}` variadic catchall inits to multiple body-swapped structs as a quick way to make call sites compile. These inits survive body-swap removal and silently break method dispatch in the restored upstream code. Four were found and removed during Phase 8 (`MessageThreadView`, `ChatEmptyState`, `SlashCommandPopup`, `ChatContentView`'s `messageThread` closure shadow). Grep `init(_ args: Any\.\.\.)` before every un-body-swap.
4. **Out-of-band stream signals need byte-for-byte mirror sentinels.** Don't redesign the protocol — copy upstream's exact sentinel format into the Intel conformer. The `\u{FFFE}reasoning:` sentinel is reused for reasoning + stats + tool hints; mirror each one identically so the decode site stays architecture-agnostic.
5. **Type-checker overflow on long chained `.onChange` modifiers is real on Swift 6.3.** Extract handler closures into helper methods AND group multiple modifiers into dedicated `ViewModifier` structs. The split `.modifier(BodyLifecycleHandlers(...))` + `.modifier(SpeechObservers(...))` approach in FloatingInputCard's `var body` solved persistent "unable to type-check this expression in reasonable time" errors that wouldn't yield to handler-extraction alone.

### Git state at Phase 8 close

- **Branch:** `intel-fork`
- **Tag:** `m10.5-phase-8-complete`
- **Latest commit:** `1dc24c5e` — "Phase 8C polish: respect Reasoning Mode chip + populate Context Budget"
- **Working tree:** clean
- **Build state:** `swift build --arch x86_64` → 0 errors; `xcodebuild Release x86_64` → BUILD SUCCEEDED; binary is `Mach-O 64-bit executable x86_64`; app launches and renders the upstream Osaurus chat UI end-to-end.

### Closing note

M10.5 reached its destination. A 2017 MacBook Air running macOS Sequoia 15.7.7 now hosts the original Osaurus chat experience — same markdown renderer, same sidebar, same FloatingInputCard, same Context Budget popover — streaming DeepSeek V4 Pro responses with full reasoning-mode control. Eight days of work; ~50 commits; ~3,000 lines of upstream code restored to Intel; ~700 lines of conformer surface added; four "type-checker pacifier" landmines defused; the sentinel pattern for cross-architecture stream signals codified.

The destination was the path. 🦕☀️

---

## M11 Phase 11.0 — Open the Settings window + disable Group C in sidebar (IN PROGRESS)

**Date:** 2026-05-30
**Branch:** `intel-fork`
**Status:** Phase 11.0 + 11.0-bis landed and built clean; manual click-through verified Settings window opens with Cmd+,, chat + MCP still work in parallel, Cmd+, twice re-uses the window. The empty-content-area bug found on first launch was fixed in 11.0-bis. Full Phase 11.0 click-through (sidebar rows visible + Group C greyed out) pending Renée's next launch with the 11.0-bis build.

### What Phase 11.0 unblocks

Until this commit, `AppDelegate.showManagementWindow(initialTab:)` was stubbed to route to `showChatWindow()` on Intel, and `Packages/OsaurusCore/Views/Management/ManagementView.swift` was body-swapped to a single `AppleSiliconOnlyTab` placeholder. None of the 19 upstream tabs (`ManagementTab` enum at `Models/Configuration/ManagementTab.swift:12-31`) were reachable from the Intel build.

After Phase 11.0 + 11.0-bis:
- Cmd+, opens a real Management window (1000×700, min 900×640)
- All 19 tabs visible in the sidebar
- Group C tabs (Models / Voice / Memory / Sandbox / Schedules / Insights — see `ManagementTab.isAvailableOnIntel`) are visibly greyed out (`.opacity(0.45)`), not clickable (`.disabled(true)`), with a hover tooltip ("Not available on Intel — requires Apple Silicon")
- Group A and B tabs are clickable; their bodies still render the existing `AppleSiliconOnlyTab` placeholders (subsequent phases 11.A.1 onwards replace these with real upstream restorations)

### Sub-phase log

| Phase | Commit | What |
|---|---|---|
| 11.0 | `eaba2e83` | Un-body-swap `ManagementView`. Add Intel stubs for the three excluded ObservableObjects ManagementView observes: `ManagementBadgeStore` + `ManagementBadgeSnapshot`, `IncomingPairCoordinator`, `AgentInvite` (all in `IntelManagerConformers.swift`). Add `isAvailableOnIntel: Bool` computed + `Sendable` conformance to `ManagementTab`. Extend `SidebarItemData` with `isDisabled` + `disabledHelp`; apply `.disabled(true) + .opacity(0.45) + .help(...)` + hover suppression to `SidebarItemView` when `isDisabled`. Wire `AppDelegate.showManagementWindow` to actually construct the NSWindow with the existing `updater: UpdaterViewModel` injected as the EnvironmentObject. Extend the body-swap Intel #else stubs for `ModelDownloadView(deeplinkModelId:deeplinkFile:)`, `AgentsView(deeplinkAgentId:)`, `ConfigurationView(searchText:)`, `IncomingPairSheet(invite:onCompleted:)` so the un-body-swapped `ManagementView.contentView(for:)` switch type-checks. |
| 11.0-bis | `a10020e2` | Fix empty-content-area bug. The first window construction used `NSWindow(contentViewController:)` which lets SwiftUI render at a zero frame on first paint. Switched to upstream `WindowManager.createWindow` order: build the NSWindow with explicit `contentRect`, attach the hosting controller after, call `host.view.layoutSubtreeIfNeeded()`, then re-apply `setContentSize(defaultSize)` so the first paint uses the intended dimensions. Same 1000×700 / 900×640 / `Cmd+,`-reuses-existing behavior. |

### Lesson captured

`NSWindow(contentViewController:)` is unsafe for SwiftUI on macOS when you don't pre-layout. The upstream `WindowManager` makes this explicit with a "force set content size again" comment + an explicit `layoutSubtreeIfNeeded` call. Any future Intel window construction should mirror that pattern, not the convenience initializer.

### Files modified across Phase 11.0 + 11.0-bis

- `Packages/OsaurusCore/AppDelegate.swift` — `managementWindow: NSWindow?` property + real `showManagementWindow` implementation (corrected in 11.0-bis)
- `Packages/OsaurusCore/Views/Management/ManagementView.swift` — un-body-swapped + `sidebarItems` marks Group C disabled on Intel
- `Packages/OsaurusCore/Views/Management/SidebarNavigation.swift` — `SidebarItemData` extended + `SidebarItemView` applies the disabled treatment
- `Packages/OsaurusCore/Models/Configuration/ManagementTab.swift` — `Sendable` conformance + `isAvailableOnIntel` computed
- `Packages/OsaurusCore/Models/Chat/IntelConformers/IntelManagerConformers.swift` — `ManagementBadgeStore` + `ManagementBadgeSnapshot` + `IncomingPairCoordinator` + `AgentInvite` Intel stubs
- `Packages/OsaurusCore/Views/Agent/IncomingPairSheet.swift` — Intel #else stub extended with `init(invite:onCompleted:)`
- `Packages/OsaurusCore/Views/Model/ModelDownloadView.swift` — Intel #else stub extended with `init(deeplinkModelId:deeplinkFile:)`
- `Packages/OsaurusCore/Views/Agent/AgentsView.swift` — Intel #else stub extended with `init(deeplinkAgentId:)`
- `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift` — Intel #else stub extended with `init(searchText: Binding<String>)`

### Pending Phase 11.0 click-through (next launch by Renée)

After rebuild + relaunch with `a10020e2`:

- [ ] Open Settings → window opens AND content area renders (1000×700 with sidebar + tab body visible, not the empty black area from the first launch)
- [ ] Sidebar shows all 19 tab rows with their icons + labels
- [ ] Group C rows visibly greyed out (~45% opacity)
- [ ] Hover on a Group C row → tooltip "Not available on Intel — requires Apple Silicon"
- [ ] Clicking a Group C row does nothing
- [ ] Group A and B tabs clickable; their bodies render the existing `AppleSiliconOnlyTab` placeholders
- [ ] Sidebar collapse arrow (top-left) toggles expanded ↔ collapsed (220px ↔ 64px)
- [ ] Cmd+, twice doesn't duplicate the window (verified in 11.0 launch ✅)
- [ ] Chat window still works (verified in 11.0 launch ✅)
- [ ] MCP still responds on 1338 (verified in 11.0 launch ✅)

### Up next after Phase 11.0 click-through succeeds

Phase 11.A.1 (bundled commit): un-body-swap `ThemesView` + `IdentityView` + `SlashCommandsView`. OpenCode-leashed since these are mechanical un-body-swaps. Plan doc at `~/.claude/plans/okay-it-is-time-pure-tower.md` has the full per-phase sequencing.

---

## M11 Phase 11.0 — Settings window operational (CLOSURE)

**Date:** 2026-05-31
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE**

### The four-round saga

Phase 11.0 took FOUR sub-phases to actually ship, with three of them "fixing" a window that was never even being shown. The root cause was a SwiftUI/AppKit gotcha that became invisible because of a coincidental window-title match.

| Sub-phase | Commit | What was attempted | What it actually did | Verdict |
|---|---|---|---|---|
| 11.0 | `eaba2e83` | Un-body-swap ManagementView, sidebar disabled treatment, AppDelegate hand-rolled NSWindow | All correct, but unreachable via Cmd+, | Necessary, insufficient |
| 11.0-bis | `a10020e2` | NSWindow pre-layout + setContentSize pattern from upstream `WindowManager.createWindow` | Useful hardening for SwiftUI-in-NSHostingController, but NOT the blocker | Belt-and-braces |
| 11.0-ter | `56621f19` | `window.isOpaque = true` + `window.backgroundColor = .windowBackgroundColor` + `window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)` mirroring `ChatPanel` | Useful hardening, also NOT the blocker | Belt-and-braces |
| **11.0-quater** | **`7c9bc1b2`** | **Replace `.appSettings` command group with custom button calling `AppDelegate.shared?.showManagementWindow()` bound to Cmd+,** | 🎯 **THE actual fix** | Blocker resolved |

### Root cause (filed in the "wish I'd checked first" bin)

`App/osaurus/osaurusApp.swift` defined a SwiftUI scene:

```swift
var body: some SwiftUI.Scene {
    Settings {
        EmptyView()    // ← what Cmd+, was actually rendering
    }
    .commands { aboutCommand }
}
```

SwiftUI binds Cmd+, to the `Settings { ... }` scene automatically. Our hand-rolled `AppDelegate.showManagementWindow` was never being called by Cmd+, — the SwiftUI Settings scene was, with its `EmptyView()` body.

The masking: SwiftUI's Settings scene auto-titles its window `"<AppName> Settings"` — which exactly matched the `"Osaurus Settings"` title I'd set on the hand-rolled NSWindow in `showManagementWindow`. Three rounds of debugging targeted a window that wasn't even on screen.

### The fix (Phase 11.0-quater)

`App/osaurus/osaurusApp.swift` gains a `settingsCommand` that replaces the default `.appSettings` group:

```swift
var settingsCommand: some Commands {
    CommandGroup(replacing: .appSettings) {
        Button {
            AppDelegate.shared?.showManagementWindow()
        } label: {
            Text(verbatim: "Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
```

The empty `Settings { EmptyView() }` scene is kept as a placeholder so SwiftUI doesn't synthesize its own fallback Settings menu item. The actual Cmd+, key chord lands on our hand-rolled NSWindow.

### Concurrent crisis: iCloud apocalypse + Documents → Developer folder move

While debugging Phase 11.0-ter, iCloud Drive (Documents & Desktop sync was on) decided to re-upload the entire `~/Documents/osaurus/build/` derived data tree — **441 GB of upload queue, 467,840 items**. `cloudd` pinned at 23% CPU thrashing indefinitely. Triggered by a partial folder move attempt that put iCloud's sync state into a circular loop.

Recovery sequence:
1. Identified split state: half in `~/Documents/osaurus/` (with `.git`, `Packages`, `build`), half in `~/Developer/osaurus/` (with `App`, workspace, docs)
2. Confirmed no file overlap between the two halves → safe to merge
3. Moved `.git` + `.github` + `Packages` → Developer with `mv` (metadata-only on same APFS volume, instant)
4. Deleted `build/intel`, `build/intel-release`, `build/intel-test` (~5.5 GB of derived data) and ultimately the entire `build/` dir
5. Removed iCloud sync-conflict ghosts: `refs/heads/intel-fork 2` zero-hash ref + `Osaurus_Intel_Fork_PathB 2.md` vault file
6. Confirmed `~/Documents/osaurus/` empty → `rmdir` → iCloud gave up its 441 GB upload queue
7. Clean rebuild from `~/Developer/osaurus/`: 3 min Debug build, BUILD SUCCEEDED, binary verified to contain Phase 11.0-quater's `showManagementWindow` symbol via `nm`

### Two new lessons captured

1. **SwiftUI's `Settings { ... }` scene silently hijacks Cmd+,.** Any hand-rolled NSWindow-based settings path MUST replace `.appSettings` in `.commands`, or the SwiftUI scene wins. The window-title default for SwiftUI Settings is `<AppName> Settings` — be aware of coincidental title matches with hand-rolled windows. Audit checklist: before debugging an "empty window" caused by SwiftUI-in-NSWindow, confirm that the NSWindow code is actually being called. Add a `print` to the construction path. Two minutes of verification beats three rounds of speculation.
2. **Xcode derived data is not portable across folder moves.** Despite `ModuleCache.noindex/` and `CompilationCache.noindex/` looking "warm" after a move, `XCBuildData/*.xcbuilddata` files contain absolute paths to the original location (specifically `SourcePackages/artifacts/.../*.xcframework`). Any cross-directory rebuild fails until the entire derived-data directory is nuked. Treat derived data as ephemeral; never try to preserve it across moves. **`rm -rf build/intel-debug && rebuild`** is the only safe path post-move.

### Files touched (Phase 11.0 → 11.0-quater)

- `App/osaurus/osaurusApp.swift` — new `settingsCommand` group, `+24 / -1` (the actual fix lives here, not in OsaurusCore)
- `Packages/OsaurusCore/AppDelegate.swift` — `managementWindow` property + full `showManagementWindow` implementation with pre-layout + appearance/opacity hardening
- `Packages/OsaurusCore/Views/Management/ManagementView.swift` — un-body-swapped, `sidebarItems` Intel-disabled mapping for Group C
- `Packages/OsaurusCore/Views/Management/SidebarNavigation.swift` — `SidebarItemData.isDisabled` + `disabledHelp` fields, `.disabled + .opacity(0.45) + .help` + hover suppression in `SidebarItemView`
- `Packages/OsaurusCore/Models/Configuration/ManagementTab.swift` — `Sendable` conformance + `isAvailableOnIntel: Bool` computed
- `Packages/OsaurusCore/Models/Chat/IntelConformers/IntelManagerConformers.swift` — `ManagementBadgeStore`, `ManagementBadgeSnapshot`, `IncomingPairCoordinator`, `AgentInvite` stubs
- 4 `#else` Intel stub extensions for tab View files (Model / Agents / Configuration / IncomingPairSheet) so the un-body-swapped `ManagementView.contentView(for:)` switch type-checks

### Click-through verification (Renée, 2026-05-31)

- ✅ App launches, no new crashes
- ✅ Cmd+, opens Settings window
- ✅ **Content area renders** — sidebar with all 19 tabs visible, default tab body shows the `AppleSiliconOnlyTab` placeholder for `Configuration`
- ✅ Group C rows (Models / Voice / Memory / Sandbox / Schedules / Insights) greyed at ~0.45 opacity
- ✅ Hovering Group C rows shows the tooltip "Not available on Intel — requires Apple Silicon"
- ✅ Sidebar collapse arrow toggles expanded ↔ collapsed (220px ↔ 64px); Group C icons stay muted when collapsed
- ✅ Cmd+, twice → existing window forward, no duplicate
- ✅ Chat window still works in parallel; MCP still responds on 1338
- ✅ Group A and B rows clickable; their bodies render the existing `AppleSiliconOnlyTab` placeholders (Phase 11.A onwards replaces these with real upstream restorations)

### Project location

`~/Documents/osaurus/` → `~/Developer/osaurus/`. All path references in the Obsidian vault docs swept with `sed`; in-repo `INTEL_ARCHEOLOGY.md` was already path-relative.


## M11 Phase 11.A.1 + 11.A.2 — Group A bundles 1+2: Themes / Commands / Providers / Skills (CLOSURE)

**Date:** 2026-06-01
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — four Group A tabs operational on Intel, two upstream-tier bugs found + fixed as side effects, one critical data-isolation safety net added.

### Phase log

| Phase | Commit | What |
|---|---|---|
| 11.A.0 | `8d95e796` | Conformer extensions for Themes + Commands: `ThemeShareOutcome` Intel stub mirroring excluded `ThemeShareService` public surface; `SlashCommandRegistry` Intel conformer extended with full CRUD against `SlashCommandStore` (NOT excluded) + `@MainActor` to satisfy Swift 6.3 actor-isolation against the store's static methods; `SlashCommandEditorSheet` Intel stub in `SlashCommandsSettingsSection.swift`'s `#else` block; `ShareThemeSheet` + `ImportThemeByIdSheet` Intel `#else` inits; `ServerController` Intel conformer gains `ObservableObject` (landed early for the future Identity restoration since it's pure additive). |
| 11.A.1 | `ac561742` | Plain un-body-swap of `ThemesView` + `SlashCommandsView`. Builds clean on first try because 11.A.0 laid every required surface upfront. |
| 11.A.1.x | `e9095fa6` | Theme picks in Settings → Themes propagate to chat windows on Intel. Bug surfaced during click-through: the Intel `ChatWindowState` body-swap stub never observed `.globalThemeChanged` notification (the upstream class does in `observeAppConfigurationChanges()`, which is excluded on Intel). Fix added `themeObserver: NSObjectProtocol?` + `observeThemeChanges()` + `refreshTheme()` to the stub, with cleanup in `cleanup()`. |
| 11.A.1.y | `785cdbed` | Themed-alert overlay env injection. The Delete-Theme confirmation alert rendered with a white background even when the active theme was dark. Root cause: SwiftUI's `.overlay(X)` places X as a **sibling** of the modified view, not a child — so `.environment(\.theme, themeManager.currentTheme)` set on the sidebar subtree didn't propagate into `ThemedAlertHost`, which fell back to `ThemeEnvironmentKey.defaultValue = LightTheme()`. Fix explicitly forwards the theme env onto the overlay content. Same bug almost certainly exists upstream and on Apple Silicon — the `LightTheme()` fallback happens to look close enough to NSAlert's stock chrome that it was invisible. |
| 11.A.2.0 | `2e4a3d99` | Conformer extensions for Providers + Skills (heavier batch, ~13 surfaces): `RemoteProviderManager` rewritten as `ObservableObject @MainActor` with `@Published configuration` + `providerStates` and real persistence via `RemoteProviderConfigurationStore` (NOT excluded); `SkillManager` similarly rewritten with full CRUD against `SkillStore` (NOT excluded); Intel stubs added for `PluginRepositoryService`, `PluginState`, `ClaudePluginInstallReport`; `RemoteProviderEditSheet` + `GitHubImportSheet` Intel `#else` inits mirroring upstream closure signatures (including `RemoteProviderOAuthTokens` from the not-excluded `RemoteProviderKeychain.swift`). |
| 11.A.2.1 | `b5709b04` | Un-body-swap of `RemoteProvidersView` + `SkillsView`. Two extra surfaces surfaced during the un-body-swap and were bundled in (still under the 5-gap threshold for "stop and re-plan"): `InstalledPluginsSection` `#else` stub gained `init(onMessage:)` returning `EmptyView()`; `SkillManager.exportSkillAsAgentSkills(_:)` SKILL.md exporter added (YAML frontmatter + body matching the Agent Skills spec). |
| 11.A.2.x | `62aec888` | **CRITICAL SAFETY FIX.** Intel data root isolated to `~/.osaurus-intel/`. See dedicated section below. |

### Conformer-first discipline paid off (twice)

Both bundles followed the same dance:

1. Optimistic un-body-swap of the target views.
2. Build → see what the compiler complains about.
3. If gaps > 5: STOP, revert the un-body-swap, do a focused 11.A.N.0 conformer-extension commit, then 11.A.N.1 un-body-swap on top.

Phase 11.A.1 had 8 gaps from a first attempt on Themes + Commands + Identity (Identity alone contributed 6+). Phase 11.A.2 had 13 gaps from Providers + Skills. Both well past the M10.5-codified threshold, both resolved cleanly by splitting. The pattern works.

The discipline also informed scope refinement: **Identity restoration was promoted to its own milestone (planned 11.A.5 in the renamed sequence) instead of being squeezed into 11.A.1**. The Identity cascade was 15-20+ surfaces deep — its own milestone-tier work, not a sub-phase.

### Two upstream-tier bugs found while restoring Intel

These bugs exist on Apple Silicon too — they just don't surface because of stock-chrome lookalike defaults or different observer registration paths. Worth flagging if these restorations ever PR back upstream:

1. **`.overlay()` doesn't inherit `.environment()` set before it in the modifier chain.** SwiftUI treats overlay content as a sibling of the modified view, not a child. Any time you set an environment value AND apply an overlay that depends on it, you need to forward the env explicitly onto the overlay or move the `.environment(...)` modifier to AFTER the `.overlay(...)`. `ThemedAlertHost` is the canonical victim in this codebase; there may be others.

2. **`@Environment(\.theme)` default value (`LightTheme()`) silently masks env-not-injected bugs.** Anywhere in the view tree that reads the theme env but happens to live outside the `.environment(\.theme, themeManager.currentTheme)` scope falls back to a generic light theme. Hard to notice on Apple Silicon because the result resembles macOS's stock light NSAlert appearance. Recommendation upstream: change the default to a "missing theme" stub that prints a debug warning, or thread the theme through SwiftUI environment more aggressively.

### Type-checker overflow recurrence (cleared)

Mid-11.A.1, `ThemesView`'s outer ZStack/VStack tripped Swift 6.3's "the compiler is unable to type-check this expression in reasonable time" error once. Extracted the inner `ScrollView { VStack { ... } }` to a `themesScrollContent` computed property — same remedy as M10.5 lesson #5 (Phase 8's FloatingInputCard `BodyLifecycleHandlers` / `SpeechObservers` modifier-struct split). When the working tree was later reverted and the un-body-swap retried after 11.A.0 landed all the conformer surfaces, the overflow did not reappear — turns out the conformer-surface incompleteness was contributing to the type-checker complexity, not just the view body itself. **New audit note:** when the type-checker overflows during an un-body-swap, check whether the cascade is also fueling the complexity *before* extracting helpers. Sometimes fixing conformer gaps clears the overflow without any view-side surgery.

### What landed where

User-visible:

- **Themes tab**: full upstream gallery (built-in Dark + Light + Nord + Neon + Paper + others + user-created custom themes), import-from-file, import-from-ID sheet (gated → AppleSiliconOnlyTab), share button (gated), themed delete confirmation alert, theme editor with live preview (Intel-native via `ThemeEditorView`).
- **Commands tab**: empty state with `/translate /summarize /review` example cards, real CRUD against `SlashCommandStore`'s JSON-on-disk persistence (same backend as upstream), edit/delete/toggle each command. Editor sheet itself gated → placeholder.
- **Providers tab**: list of configured remote providers (real persistence via `RemoteProviderConfigurationStore`); empty state with 9-preset quick-add cards (Anthropic / Azure OpenAI Foundry / DeepSeek / Google / Ollama / OpenAI / OpenRouter / Venice AI / xAI / Custom); add/edit sheets gated → placeholder; toggle-enable per provider works against on-disk config. Connection status badges always show "Disconnected" because the underlying `connect()` is a no-op on Intel (chat streams via the env-var `DEEPSEEK_API_KEY` path through `OsaurusServer`, not through the provider config).
- **Skills tab**: full editor (Intel-native), CRUD against `SkillStore`, import-from-JSON-data, import-from-markdown (basic H1-derived metadata), export as SKILL.md or as ZIP (ZIP only when the skill has associated assets/references — upstream's branching, not a JSON-vs-MD toggle), delete with themed confirmation alert (works thanks to 11.A.1.y).

Internal:

- 11 new Intel stub types / methods documented inline with M11 phase markers so future archive readers can trace exactly which surface came from which commit.
- `RemoteProviderManager` + `SkillManager` are now real `ObservableObject @MainActor` types — substantial conformer upgrades that subsequent phases (Agents, Configuration) can build on.

### 🛡️ CRITICAL: Intel data root isolation (Phase 11.A.2.x)

**The bug Renée caught:** during 11.A.2 click-through, deleting the DeepSeek provider via the Intel test build also deleted it from her production Apple Silicon Osaurus. Themes created via Intel showed up in production. Same `~/.osaurus/` root.

**Root cause:** `OsaurusPaths.defaultRoot` returned `~/.osaurus/` unconditionally. The Intel build and the production Apple Silicon build had different bundle identifiers and binaries but identical file roots — every settings edit, theme creation, provider mutation in the Intel test build was clobbering the user's daily-driver state.

**Fix (`62aec888`):** When `OsaurusBuild.isIntel == true`, the root is `~/.osaurus-intel/` instead. On first access of the Intel root, if it doesn't exist AND `~/.osaurus/` exists, COPY (not move) the production folder into the Intel root — a one-time snapshot so the user doesn't lose themes/providers/skills/sessions when switching to Intel. After the seed, the two roots diverge: Intel never writes to `~/.osaurus/`; production never reads from `~/.osaurus-intel/`.

**Why this matters beyond M11:** every Intel test session before `62aec888` was potentially mutating Renée's production data. The damage from this single session is recoverable (deepseek re-added, custom test themes can be deleted from production manually), but if this hadn't been caught now, it would have compounded over every future Intel test cycle. **This bug should have been caught on Day 1 of the Intel fork** — Apple Silicon and Intel binaries sharing a writable data root is a fork-design failure. The fact that it survived through M1 → M10.5 (~50 commits, 8 days) is a lesson in how easy it is for "the path module just works" assumptions to mask cross-build cross-talk. Audit any centralised path / config / cache module the first time you introduce a build variant.

**Lessons captured:**

1. **A fork is not isolated unless it has its own data root.** Bundle identifier separation, binary separation, even Xcode workspace separation aren't enough — if both builds write to the same `~/Library/Application Support/...` or `~/.appname/` path, the user gets cross-pollination they didn't ask for. Always test cross-build isolation explicitly when forking.
2. **Port collision is a sibling concern.** Both Intel and production Osaurus default to port 1338 for the local HTTP server. NIO fails to bind on whichever app launches second. Workflow rule for now: quit one before launching the other. A future Intel build might default to 1339 (with the trade-off that MCP clients/scripts expecting 1338 won't see Intel without reconfiguration).
3. **Xcode derived data is not portable across folder moves.** Already codified in the 11.0 closure but worth re-stating: `XCBuildData/*.xcbuilddata` contains absolute paths to package resolution targets (e.g. `SourcePackages/artifacts/.../*.xcframework`). When a project moves between filesystem locations, the entire derived-data directory must be nuked. `ModuleCache.noindex/` and `CompilationCache.noindex/` look "warm" but contain stale absolute paths.

### Files touched (Phase 11.A.0 → 11.A.2.x)

Conformer / type stubs (in `Models/Chat/IntelConformers/`):
- `IntelStubConformers.swift` — `RemoteProviderManager` rewritten as `ObservableObject @MainActor`; new `PluginRepositoryService` + `PluginState` + `ClaudePluginInstallReport` stubs
- `IntelDataConformers.swift` — `SlashCommandRegistry` extended (CRUD against `SlashCommandStore`); `SkillManager` rewritten as `ObservableObject @MainActor` (CRUD against `SkillStore` + import/export including `exportSkillAsAgentSkills` SKILL.md formatter); `ServerController` gained `ObservableObject`; new `ThemeShareOutcome` public stub

Views (un-body-swapped):
- `Views/Theme/ThemesView.swift`
- `Views/SlashCommand/SlashCommandsView.swift`
- `Views/Settings/RemoteProvidersView.swift`
- `Views/Skill/SkillsView.swift`

Views (`#else` Intel stubs extended with proper inits):
- `Views/Theme/ShareThemeSheet.swift`
- `Views/Theme/ImportThemeByIdSheet.swift`
- `Views/Settings/RemoteProviderEditSheet.swift`
- `Views/Settings/SlashCommandsSettingsSection.swift` (now also defines `SlashCommandEditorSheet`)
- `Views/Skill/GitHubImportSheet.swift`
- `Views/Skill/InstalledPluginsSection.swift`

Polish + safety:
- `Views/Management/ManagementView.swift` — themed-alert env injection on the overlay (11.A.1.y)
- `Managers/Chat/ChatWindowState.swift` — Intel stub observes `.globalThemeChanged` + has `refreshTheme()` (11.A.1.x)
- `Utils/OsaurusPaths.swift` — Intel data root isolation to `~/.osaurus-intel/` (11.A.2.x)

### Click-through verification (Renée, 2026-06-01)

Themes:
- ✅ Real theme gallery (built-in + custom)
- ✅ Active theme indicator
- ✅ Click a theme → applies; **chat window updates instantly too** (11.A.1.x verified)
- ✅ Import-from-file works
- ✅ Import-from-link → Apple-Silicon-only placeholder
- ✅ Share → Apple-Silicon-only placeholder
- ✅ Theme editor with live preview works
- ✅ Delete confirmation **renders dark on dark theme** (11.A.1.y verified)

Commands:
- ✅ Empty state with example cards
- ✅ New Command → editor placeholder (editor not yet Intel-native; deferred)
- ✅ Hand-rolled JSON command in `~/.osaurus-intel/commands/` appears in list on next open (persistence verified via the Shakespearean `/shakespeare` test command)

Providers:
- ✅ Empty state with 9 preset quick-add cards
- ✅ Click preset → "Remote Provider Edit" placeholder sheet (520×420)
- ✅ "Add Provider" header → same placeholder
- ✅ Configured provider appears with toggle + edit + delete buttons
- ✅ Toggle/delete persist on disk

Skills:
- ✅ Empty state with example cards
- ✅ "Create Skill" → Intel-native full editor sheet, with name/description/version/author/category/instructions/enabled
- ✅ Create + edit + toggle + delete all work, persistence via SkillStore
- ✅ Export as SKILL.md works (verified hand-readable YAML frontmatter)
- ✅ GitHub Import → AppleSiliconOnlyTab placeholder

Regression:
- ✅ Cmd+, opens Settings (11.0-quater)
- ✅ Group C still greyed (11.0)
- ✅ Chat streaming works (after a DeepSeek balance top-up the user had forgotten about, which initially looked like a code regression but was HTTP 402 from the API — the path through `CloudChatEngine.streamChat` was never broken)
- ✅ Slash command `/shakespeare` produces theatrical filth on demand 🎭

### Up next

Phase 11.A.3: un-body-swap `ConfigurationView` (the general Settings tab). Expect MLX-specific sub-sections (default local-model picker, runtime tuning) that need selective gating; other config (default chat model, system prompt, default temperature, generative-greeting toggle, clipboard monitoring toggle) should back onto the existing `AppConfiguration` Intel conformer.

---

## M11 Phase 11.A.3 — ConfigurationView (general Settings tab) (CLOSURE)

**Date:** 2026-06-01
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE**

### Phase log

| Phase | Commit | What |
|---|---|---|
| 11.A.3.0 | `6baf52d5` | First conformer-extension wave (18 surfaces): new `Hotkey` struct + `PreflightSearchMode` enum (both live in excluded files upstream); `ChatConfiguration` Intel stub extended with ~10 fields (hotkey, coreModel*, workMax*, preflightSearchMode, greetingPersona); `ModelPickerItemCache` gains ObservableObject; `AppDelegate.serverController` (IntelServerControllerSurface) + `applyChatHotkey()`; `ToolRegistry.clearPolicy`; `SpeechService.loadedModelId`; `GenerativeGreetingService.defaultPersonaInstruction`. |
| 11.A.3.0-bis | `0261fed3` | Wave-two (6 more surfaces surfaced by the un-body-swap probe): `ChatConfiguration` convenience init (22 params) + `adopt(_:)`; `ChatConfigurationStore.save` folds into the shared singleton; `ToolRegistry` ObservableObject; `HotkeyRecorder` Intel `#else` init. `topPOverride` intentionally kept `Double?` (not upstream's `Float?`) to match `ChatView.swift:2148`'s consumer. |
| 11.A.3.1 | `0b5116c8` | Un-body-swap. Wave-three (3 surfaces): `PreflightSearchMode.helpText`; init `topPOverride` accepts `Float?` → bridged to `Double?`; `ToolRegistry` real per-tool `[String: ToolPermissionPolicy]` map (configuredPolicy/setPolicy/clearPolicy). |
| 11.A.3.2 | `519394de` | Two click-through bug fixes (below). |

### ConfigurationView is the deepest-coupled tab

It needed ~27 conformer surfaces across THREE waves — far more than Themes/Commands (8) or Providers/Skills (13) — because it touches the most cross-cutting services of any settings tab: hotkey, voice, MLX runtime, work-agent params, memory, tool permissions, server config. Each section pulls a different amputated subsystem. **Audit note:** the most transitively-dependent views surface their cascade in waves — fixing wave-one exposes wave-two, etc. Don't assume one conformer-extension commit clears it; budget for 2-3 probe→fix cycles on integration-point views.

### Two click-through bugs (11.A.3.2)

1. **Dock icon spawned a new chat window on every click.** `applicationShouldHandleReopen` → `showChatWindow()` → unconditional `createWindow()`. Fixed with `focusExistingChatWindowOrCreate()` (prefer last-focused, fall back to first open, only create when none) + respecting the `hasVisibleWindows` flag.
2. **Tool-permission picker couldn't select "Auto" for destructive tools** (Run Shell / Git Commit). The Intel `ToolRegistry.setPolicy` collapsed `.auto` into a `removeValue` (treating Auto as "clear override"); for tools whose default is `.ask`, clearing made `effectivePolicy` fall back to `.ask`, snapping the picker back. Fixed by storing all three values explicitly.

### Persistence note

`ChatConfigurationStore.save` folds view mutations into the shared `ChatConfiguration` singleton, so config round-trips within a session (after clicking "Save Changes"). On-disk persistence across app restart is deferred M11 follow-up. The Configuration tab uses an explicit "Save Changes" button — edits live in `tempX` @State until saved (matches upstream; not auto-save).

### Click-through verification (Renée, 2026-06-01)

✅ Full form renders; General/Chat/Work sections; preflight picker + help text; tool permission pickers (Auto sticks); Save Changes persists across tab switches; dock no longer spawns duplicates. Group A reached 5/7.

---

## M11 Phase 11.A.4 — AgentsView, THE BEAST (CLOSURE)

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — the single largest restoration in the entire Intel fork.

### Scope

`AgentsView` + `AgentDetailView` = **~6,079 lines**, the front-end for the entire agent-database subsystem (per-agent SQLite, schedules, watchers, pinned facts, episodes, dynamic tools, relay/Bonjour, agent bundles, per-agent voice/TTS, plugin route tabs). Almost all of it is amputated on Intel.

Renée's strategic call: **full faithful restore** (vs. a slimmer hand-built editor). The upstream view tree compiles + renders verbatim, with every amputated sub-feature falling through to `AppleSiliconOnlyTab` placeholders.

### The cascade by the numbers

- **249 errors at peak** (un-body-swap probe), ~70 unique surfaces, ~15 sub-views.
- Resolved across **one new foundation file + targeted edits to ~13 files**, over ~6 build-probe-fix cycles.
- Done in a **single un-body-swap commit** (`3696bb9d`, not split into .0/.1) because the surfaces are so interdependent the view doesn't compile until nearly all land. A follow-up commit (`665532d4`) fixed three click-through issues.

### What got built

**New file — `IntelAgentConformers.swift` (~480 lines):**
- Types: `AgentDeleteResult`, `SandboxCleanupNotice`, `AgentRelayStatus` (.disconnected/.connecting/.connected(String)/.error), `AgentBundleManifest`
- Managers (ObservableObject): `RelayTunnelManager`, `ScheduleManager`, `WatcherManager`, `RemoteAgentManager`
- Services/stores: `AgentBundleService` (+ImportPreview/BundleExportResult), `AgentDatabaseStore`, `AgentSecretsKeychain`, `AgentStore`, `BonjourAdvertiser`, `ChatHistoryDatabase`, `SchedulerDatabase`, `LocalAgentBridge`, `PocketTTSVoiceCatalog`
- Sub-view placeholders: `HomeTabView`, `DataTabView`, `ActivityTabView`, `ViewsTabView`, `PinnedFactsPanel`, `EpisodeRow`, `ScheduleEditorSheet`, `WatcherEditorSheet`, `RemoteAgentDetailView`
- Notification names: `agentDetailDeeplink`, `openTTSSettingsRequested`, `schedulesChanged`, `watchersChanged`

**Extended existing conformers:**
- `PluginManager` (Intel stub): a rich agent-view surface distinct from the M9 capability-bucket UI — `LoadedPlugin` (.plugin.manifest/.routes/.webConfig), `FailedPlugin` typealias + `FailedPluginInfo.lastKnownManifest`, plugins/loadedPlugin/loadError/removeFromQuarantine, and a full `PluginManifest` with nested `RouteAuth` (enum, for switch-exhaustiveness) / `RouteSpec` / `WebConfig` / `ConfigSpec` / `Capabilities`
- `AgentManager`: delete → `AgentDeleteResult`; setCustomAvatar/clearCustomAvatar; effectiveAutonomousExec returns the real `AutonomousExecConfig`; updateDefaultModel accepts `String?`
- `MemoryDatabase`: loadPinnedFacts/loadEpisodes (limit, throws), deletePinnedFact(id: String)
- `TTSService` → ObservableObject; `ToolRegistry.listDynamicTools` (returns DynamicToolRef with .name); `RemoteProviderManager.findService`; `PluginRepositoryService.uninstall`; `AppChatConfigStub.greetingPersona`

**Extended #else Intel stubs (init signatures from call sites):** RemoteAgentCard, ShareAgentSheet, AgentCapabilityManagerView (both live + draft inits), SchemaTabView, PluginConfigView, NextRunPanelView.

**ChatWindowManager:** added `createWindow(agentId:sessionData:)` overload (internal — ChatSessionData is internal) so history rows reopen sessions.

### Three landmines / lessons specific to this beast

1. **Module-scope helper clash (`agentColorFor`).** Once AgentsView un-body-swaps, its top-level `agentColorFor` collides with the `fileprivate` one in `ChatEmptyState.swift` (both visible in the Intel module). Made AgentsView's `fileprivate`. **Lesson:** un-body-swapping a large view can re-expose top-level free functions that duplicate ones in other files compiled into the same Intel module — grep for top-level `func`/`let` name clashes after un-body-swap.

2. **Two type-checker overflows** in long `.onReceive`/`.onChange` modifier chains (Swift 6.3) — extracted `handleAgentDetailDeeplink` + `handleToolsListChanged` to methods (M10.5 lesson #5 again — this view hit it twice).

3. **`RouteAuth` must be an enum, not a RawRepresentable struct,** because the view does `switch route.auth { case .none, .verify, .owner }` and needs exhaustiveness. First attempt as a struct-with-static-lets failed the switch.

### Click-through fixes (11.A.4.1, commit `665532d4`)

1. **Agent persistence.** The Intel `AgentManager` was a hollow stub — `agents` was a throwaway array, `add`/`update` no-ops, `delete` always returned deleted:true. So created agents didn't appear and deleting Default falsely "succeeded." Fixed with **real on-disk persistence** (same pattern as SlashCommandStore/SkillStore): custom agents are JSON files under `OsaurusPaths.agents()`; the built-in Default (`Agent.defaultId`, `isBuiltIn=true`) is pinned first and never written; add/update persist+reload, delete removes the file (and refuses Default → returns deleted:false, which is correct: Default is mandatory). `reload()` drives the @Published grid refresh.

2. **Giant "Next Run" banner.** `NextRunPanelView`'s `AppleSiliconOnlyTab` placeholder (with expanding Spacers) sat ABOVE the detail tab bar and swallowed half the view. Since scheduling is amputated there's never a next run, so the Intel stub now renders `EmptyView`.

3. **Providers "Disconnected" badge.** Enabled providers now seed `providerStates[id].isConnected = true` (chat streams via OsaurusServer + env-var, not a per-provider connection), so the badge reads "Connected."

### Two "looks like a bug, is actually correct" findings

- **"Default disappeared from the grid."** Correct behavior: the Agents grid renders only `customAgents` (filter `!isBuiltIn`); Default is built-in and configured via Settings → Configuration, never a grid card. The *old* hollow stub faked a Default card (its fake Default had `isBuiltIn=false`); the real `Agent.default` has `isBuiltIn=true`, so it's properly excluded now. The "disappearance" is the fix landing.
- **"Production agents showing up."** The one-time `~/.osaurus` → `~/.osaurus-intel` seed copied production custom agents into the Intel data dir. Verified isolation is airtight: production dir untouched, new Intel agents (e.g. "Lala") exist only in Intel. Working as designed (11.A.2.x).

### Click-through verification (Renée, 2026-06-02)

✅ Agent grid; detail view (tabs at top, no banner); create→card appears; edit persists; delete custom works; Default correctly absent from grid; survives restart; Providers "Connected"; amputated sub-tabs render graceful empty-states or placeholders; chat + `/shakespeare` still work; no dock duplicates.

**Group A reached 6/7** (Themes, Commands, Providers, Skills, Configuration, Agents). Only Identity (Phase 11.A.5) remains.

### Up next

Phase 11.A.5 — Identity (`IdentityView`). The M4↔Rosy sync backbone and the deepest Identity cascade in the codebase (OsaurusIdentity namespace, MasterKey, OsaurusID, IdentityDrift, AgentManager address methods assignAddress/rotateAddress/revokeAddress, ServerController.restartServer, sub-views IdentitySetupCard/MasterAddressSection/AgentAddressesSection/DeviceSection/DangerZoneSection/RecoverFromMnemonicSheet/RecoveryPhraseSheet). The `ServerController` ObservableObject conformance was already pre-landed in 11.A.0 in anticipation.

---

## M11 Phase 11.A.5 — IdentityView (CLOSURE) + GROUP A COMPLETE 🏆

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE — and FUNCTIONAL, not just restored.**

### The pleasant surprise

Identity isn't a placeholder on Intel — it genuinely works. The M4 ↔ Rosy
cryptographic identity-sync backbone runs on a 2017 Intel MacBook Air.

**Why:** of the 19 files in `Identity/`, only `OsaurusIdentity.swift` (the
158-line orchestrator) was excluded — and only as *collateral* from the
original mass-exclusion (it imports nothing but CryptoKit / Foundation /
LocalAuthentication; no MLX, no sandbox). The entire crypto/key/recovery
substrate — `MasterKey`, `AgentKey`, `DeviceKey`, `MasterKeyMnemonic`,
`MasterMnemonicStore`, `RecoveryManager`, `APIKeyManager`,
`IdentityHealthCheck`, `CryptoHelpers`, `IdentityModels` — was already
compiling on Intel.

So this was the cleanest possible restoration: **un-exclude > stub.** Remove
one line from `Package.swift`'s exclude list and the orchestrator comes back
whole.

### Cascade

Only 42 errors / **3 unique surfaces** (vs the Agents beast's 249 / 70):
- `OsaurusIdentity` (resolved by un-excluding the file)
- `AgentManager.assignAddress(to:)` / `rotateAddress(of:)` / `revokeAddress(of:)`
- `ServerController.restartServer()`

All the sub-views (`IdentitySetupCard`, `MasterAddressSection`,
`AgentAddressesSection`, `DeviceSection`, `DangerZoneSection`,
`RecoverFromMnemonicSheet`, `RecoveryPhraseSheet`, `IdentityDriftBanner`)
live inside `IdentityView.swift` itself, so they came back for free with the
un-body-swap. `OsaurusID`, `IdentityPhase`, `IdentityDrift`, `IdentityInfo`
all already resolved.

### The functional part

The 3 `AgentManager` address methods were mirrored **byte-for-byte from
upstream** (not stubbed) — `assignAddress` / `rotateAddress` / `revokeAddress`
+ the private helpers `nextUnusedAgentIndex()` and
`revokeActiveKeys(forAudience:)`. Every dependency they touch
(`AgentKey.deriveAddress`, `MasterKey.getPrivateKey`,
`OsaurusIdentityContext.biometric`, `APIKeyManager.listKeys/revoke`) is live
on Intel, so per-agent addresses really derive from the master key.

`ServerController.restartServer()` is the only genuine no-op: the Intel
server (`OsaurusServer` in `AppDelegate`) validates access keys against the
live `APIKeyManager` per-request, so there's no cached key table to reload
after an address rotation.

### Click-through verification (Renée, 2026-06-02)

✅ Master Address renders a real OsaurusID
(`0x39Cfb90b604bE45a4c277E603e0aF4E860a9DEAf`); agent addresses derived for
all 4 custom agents (Sunny Complete / Text Extractor / Sunny 1k / Lala);
device section shows device ID; "Backed up in iCloud Keychain" + Active;
View Recovery Phrase works (biometric); Danger Zone present. All 6 other
Group A tabs + chat + `/shakespeare` still green.

### 🏆 GROUP A COMPLETE — 7/7

| Tab | Technique | Functional |
|---|---|---|
| Themes | un-body-swap + conformers | ✅ fully |
| Commands | un-body-swap + real SlashCommandStore | ✅ fully |
| Providers | un-body-swap + real config persistence | ✅ fully |
| Skills | un-body-swap + real SkillStore | ✅ fully |
| Configuration | un-body-swap + 27 conformer surfaces (3 waves) | ✅ session-scoped |
| Agents | the ~6000-LOC beast + real agent persistence | ✅ fully |
| Identity | un-exclude > stub + real crypto address derivation | ✅ fully functional |

### Up next

Group B (partial restores): Server, Permissions, Storage, Plugins, Tools,
Watchers. Then the Group C verification pass + Phase 11.D documentation/tag.
Notably, the sidebar already shows Server / Permissions / Storage as
clickable (they were never Group C), so they likely have partial
functionality already — Group B is mostly verification + selective gating of
amputated sub-sections.

---

## M11 Phase 11.B.1 — Group B wave 1: Server, Permissions, Storage, Watchers (CLOSURE)

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** (4 of 6 Group B tabs; Plugins + Tools deferred to 11.B.2)

### What landed

| Tab | Technique | Functional |
|---|---|---|
| Permissions | un-exclude `SystemPermissionService` | ✅ fully (real macOS TCC checks) |
| Storage | un-exclude `StorageMigrator` + `StorageExportService` + `AttachmentBlobStore` | ✅ fully (real SQLCipher backup/export/key-rotation) |
| Server | un-body-swap + `ServerController` surface | ✅ (Overview + API Reference; Settings sub-tab gated) |
| Watchers | un-body-swap + `WatcherManager` surface | ✅ (list + real editor sheet; create no-ops) |

### The un-exclude pattern keeps paying off

Permissions + Storage joined Identity as "fully functional via un-exclude > stub." Their services had **zero amputated dependencies** — excluded only as collateral. Un-exclude + gate the 3-4 amputated one-liners (`AudioInputManager.refreshDevices`, `MemorySearchService.rebuildIndex`, `StorageMigrationCoordinator.begin/endMutating`) with `#if !OSAURUS_INTEL`. `AttachmentBlobStore` was also un-excluded (clean CryptoKit/Foundation), replacing the throw-only Intel stub; `referencedHashes` narrowed to internal because `ChatTurnData` is an internal conformer on Intel.

### Conformer surfaces added

`ServerController`: `localNetworkAddress` ("127.0.0.1"), `serverHealth` (.running), `startServer()` no-op, `port` corrected 1337→1338. `ModelManager`: static `discoverLocalModels()` → empty `[LocalModelRef]`. `FoundationModelService` stub (`isDefaultModelAvailable` → false). `WatcherManager`: `isRunning(_:)`, `runNow(_:)`, `setEnabled(_:enabled:)`, `create(... parameters:)`. Removed the duplicate `WatcherEditorSheet` from `IntelAgentConformers` (WatchersView provides the real one now).

### Click-through bug (11.B.1-bis, commit `42e4c277`)

**Server tab crashed the window on open.** `ServerView` reads `@EnvironmentObject var server: ServerController` in its body, but `AppDelegate.showManagementWindow` only injected `.environmentObject(updater)` — ServerController was never in the window environment → "No ObservableObject of type ServerController found." IdentityView survived the same missing injection only because it touches `server` lazily (in a key-rotation method, never the body). Fix: inject `ServerController.shared` into the ManagementView environment. **Lesson:** SwiftUI resolves `@EnvironmentObject` lazily, so a missing injection can hide for an entire tab and only crash when a *different* view reads the object in its body. When restoring views that take environment objects, verify every required object is injected at the window root, not just the ones that happen to be accessed eagerly.

### Click-through verification (Renée, 2026-06-02)

- ✅ **Permissions**: real OS permission states (Automation/Calendar/Mail/Contacts/Notes/Accessibility/Full Disk Access granted with live counts; Location/Screen Recording show correct un-granted states). The TCC prompts attribute to "Terminal" not "Osaurus" — a dev-launch artifact (raw binary launched from terminal; a bundled double-clicked app would say Osaurus), not an Intel bug.
- ✅ **Storage**: SQLCipher backup/export genuinely work.
- ✅ **Server** (after 11.B.1-bis): Overview shows URL `http://127.0.0.1:1338`, Running status, real access keys + relays; Settings sub-tab gated; API Reference shows the full endpoint catalog.
- ✅ **Watchers**: empty state + the real upstream Create-Watcher sheet (Browse folder / instructions); saving no-ops (watcher runtime amputated).

### Deferred: Plugins + Tools (Phase 11.B.2)

The two deepest Group B tabs (49 + 64 surfaces). They hit a real dependency chain: `JSONValue` (in excluded `Models/API/OpenAIAPI.swift`) → `SandboxPlugin` model graph → `ToolRegistry.ToolEntry`/`ToolPolicyInfo` (with `ToolSpecTokenEstimator`) → full `PluginState` + `PluginRepositoryService`/`PluginManifest` extensions + `SandboxPluginLibrary`/`MCPProviderManager` stubs. Scoped as a separate focused session rather than rushed at the tail of the marathon. `SandboxPlugin.swift` + `ToolSecretsKeychain.swift` were confirmed clean (0 amputated refs) and are un-exclude candidates; `JSONValue` needs mirroring (or un-excluding OpenAIAPI.swift) first.

### M11 status

✅ 11.0 (Settings window) · ✅ 11.A (Group A 7/7, tagged `m11-group-a-complete`) · 🟢 11.B (Group B 4/6) · ⏳ 11.B.2 (Plugins + Tools) · ⏳ 11.C (Group C verification) · ⏳ 11.D (closure + tag `m11-settings-complete`)

---

## M11 Phase 11.B.2 — Plugins + Tools (CLOSURE) + GROUP B COMPLETE 6/6

**Date:** 2026-06-02
**Branch:** `intel-fork`
**Status:** ✅ **COMPLETE** — Group B done.

### The deepest Group B dig

PluginsView (1938 LOC) + ToolsManagerView (1406 LOC) had a real
dependency chain that justified deferring them from 11.B.1:

`JSONValue` (in excluded `OpenAIAPI.swift`, gated `#if !INTEL`) →
`SandboxPlugin` model graph → `ToolRegistry.ToolEntry`/`ToolPolicyInfo`
→ full `PluginState` + `PluginRepositoryService`/`PluginManifest`
extensions + `SandboxPluginLibrary`/`MCPProviderManager` runtime stubs →
a long tail of nested types (`RegistryCapabilities.ToolSummary/SkillSummary`,
`PluginManifest.SecretSpec/DocsSpec/DocLink`, `PluginLoadError`) and
sub-view stubs (`SandboxPluginEditorView`, `ToolSecretsSheet`).

### Techniques used (all three of the fork's restoration patterns in one tab)

1. **Un-exclude** (clean files): `SandboxPlugin.swift` (+ its nested
   spec types) and `ToolSecretsKeychain.swift` had 0 amputated refs.
   One line gated (`SandboxPathSanitizer.validatePluginFiles` → `[]`).
2. **Mirror** (gated type): `JSONValue` lives in `OpenAIAPI.swift` which
   is entirely `#if !OSAURUS_INTEL` — so the type is invisible on Intel
   even though the file isn't in the exclude list. Mirrored the enum +
   `sendableValue`/`anyValue` byte-for-byte into a conformer. (Same
   situation as `ExternalPlugin.PluginManifest` — a non-excluded file
   wholly wrapped in `#if !INTEL`, so its public types don't exist on
   Intel and our stub `PluginManifest` in `PluginManager.swift`'s `#else`
   is the only one.)
3. **Stub** (amputated runtime): `MCPProviderManager`, `SandboxPluginLibrary`,
   the editor/secret sheets — empty/no-op, rendering AppleSiliconOnly
   placeholders.

### New audit note

**A file can be absent on Intel two ways:** (a) listed in Package.swift
`exclude:`, or (b) its entire body wrapped in `#if !OSAURUS_INTEL`
*inside* a non-excluded file. Pattern (b) bit twice this phase
(`JSONValue`/`OpenAIAPI.swift`, `PluginManifest`/`ExternalPlugin.swift`):
`grep -c '"path"' Package.swift` returns 0 (not excluded) yet the type
is unavailable. When a "cannot find type X" appears for a type whose
file looks un-excluded, check the file's top for a wrapping `#if !OSAURUS_INTEL`.

### 🏆 GROUP B COMPLETE — 6/6

| Tab | Technique | Notes |
|---|---|---|
| Server | un-body-swap + ServerController surface | Overview + API Reference; Settings gated |
| Permissions | un-exclude SystemPermissionService | fully functional (real TCC) |
| Storage | un-exclude StorageMigrator/Export/AttachmentBlobStore | fully functional (real SQLCipher) |
| Watchers | un-body-swap + WatcherManager surface | list + real editor; create no-ops |
| Plugins | un-exclude SandboxPlugin + mirror JSONValue + conformer extensions | M9 three-bucket UI renders; install amputated |
| Tools | same foundation + ToolRegistry ToolEntry/ToolPolicyInfo | tool list renders; sandbox tools amputated |

Build: clean rebuild from empty .build → 124.80s, 0 errors.

### M11 status

✅ 11.0 · ✅ 11.A (Group A 7/7, tagged) · ✅ 11.B (Group B 6/6) · ⏳ 11.C (Group C verification — already greyed) · ⏳ 11.D (closure + tag `m11-settings-complete`). **All 19 settings tabs now either restored (13) or gracefully disabled (6 Group C). M11 is one verification pass + a doc/tag away from done.**

---

## M12 — Intel Chat Completeness (PLANNED, scoped 2026-06-02)

M11 restored all 19 settings tabs, but Renée's side-by-side comparison with the
production Apple Silicon build surfaced three gaps in the **chat experience
itself** — the actual product, not the settings. None are MLX-blocked.

### Gap 1 — Agent picker in chat (HIGH priority) — ✅ DONE 2026-06-03 (commit `bfdbf63e`)

The agent pill (top-center selector: "Sunny (Complete)" with a dropdown to
switch agents + "Manage Agents…") lives in `ChatToolbarDelegate`
(`Managers/Chat/ChatWindowManager.swift`), which is inside the
`#if !OSAURUS_INTEL` block. The Intel chat window (the `#else` block, ~line 910)
is a stripped-down `NSWindow` with just `window.title = "Osaurus (Intel)"` — no
NSToolbar, no agent pill. **Result: you cannot select an agent in chat.** Agents
created in the (restored) Agents settings tab can't be used.

Fix options: (a) give the Intel chat window the real NSToolbar + ChatToolbarDelegate
(agent pill) — bigger, pulls the toolbar item views; (b) add an agent picker chip
to `FloatingInputCard` next to the existing model picker — smaller, Intel-specific.
`AgentManager.shared.agents` already has real persistence (M11.A.4.1), so the data
is ready; this is purely the selection UI + wiring `windowState.agentId`.

### Gap 2 — Folder / working-directory context (MEDIUM, coupled to Gap 3)

`FloatingInputCard` already renders the Folder chip + calls
`folderContextService.selectFolder()` (`FolderContextService.shared` exists on
Intel). But the picker likely no-ops because `DirectoryPickerService` +
`FolderToolManager` are excluded. A working folder for file/shell tools needs zero
MLX. Check whether `Services/DirectoryPickerService.swift` +
`Folder/FolderContextService.swift` are clean un-exclude candidates.

### Gap 3 — Runtime tools (LARGE, the capability win)

Production shows ~152 tools (file_edit, file_read, file_search, file_tree,
file_write, shell_run, sandbox_*, plugin tools). On Intel `ToolRegistry` is an
empty stub — `listTools()` returns `[]`. The REAL `Tools/ToolRegistry.swift` is
excluded but **clean** (imports only Foundation + Combine, 0 MLX refs). BUT it
registers ~40 tool types in `registerBuiltInTools()`, many genuinely amputated:
the 20+ `DB*Tool` (agent-database) tools, sandbox tools, capability tools. The
**Foundation/Process-based file + shell tools** (`file_read`, `file_edit`,
`file_write`, `file_search`, `file_tree`, `shell_run`) live in
`Tools/FolderToolManager.swift` (excluded) and are the un-MLX subset worth
restoring.

Strategy: un-exclude `ToolRegistry.swift` + `FolderToolManager.swift` (+ whatever
clean tool files they need), and **selectively gate the amputated tool
registrations** (`#if !OSAURUS_INTEL` around the DB/sandbox/capability tool
registers) so the file/shell suite registers on Intel while the rest stays off.
This makes the Intel agent loop actually able to read/write/search files + run
shell commands in the folder context (Gap 2). Tools 2+3 land together.

### Suggested M12 order

1. **Gap 1 (agent picker)** — independent, highest user-visible value, unblocks
   "use the agents you created."
2. **Gap 3 (runtime tools)** — un-exclude ToolRegistry + FolderToolManager,
   selectively gate. The capability win.
3. **Gap 2 (folder context)** — falls out of Gap 3; wire DirectoryPickerService so
   the Folder chip picks a real working dir for the restored tools.

### State at M12 scoping

M11 complete through Group B (6/6). Branch `intel-fork`, working tree clean.
Latest commits: cb6c4670 (Plugins+Tools), 57208c08 (doc). Tags:
`m11-group-a-complete`. M11.C (Group C visual verification) + M11.D
(closure + tag `m11-settings-complete`) still pending — small, can fold into
M12 or do first.

---

## M12 Gap 1 — Agent Picker (CLOSURE, 2026-06-03, commit `bfdbf63e`)

Renée chose **PATH C — the faithful top toolbar pill** (matching the Apple
Silicon screenshot) over the lighter input-card chip. Delivered in one commit
after three click-through rounds.

### What shipped

**UI — faithful unified toolbar (centered agent pill):**

- **`Views/Common/SharedHeaderComponents.swift` — un-body-swapped.** Removed the
  outer `#if !OSAURUS_INTEL … #else AppleSiliconOnlyTab … #endif` so the upstream
  `AgentPill` (+ `HeaderActionButton` / `SettingsButton` / `CloseButton` /
  `PinButton` / `PopoverRow`) compiles natively on Intel. Added a **local
  `fileprivate agentColorFor`** (the M11.A.4 pattern — the two existing copies in
  `AgentsView.swift` / `ChatEmptyState.swift` are `fileprivate`, invisible to
  other files). Extended the Intel `DiscoveredAgent` stub with `agentDescription`
  (the only surface gap the build surfaced).
- **`ChatWindowManager.swift` (Intel `#else`) — toolbar attached.** `createWindow`
  now ties the window to the **real active agent** (`AgentManager.shared.activeAgentId`)
  instead of a throwaway `UUID()`, switches the style mask to
  `.fullSizeContentView` + transparent titlebar, and attaches a unified
  `NSToolbar`. New **`IntelChatToolbarDelegate`** (+ `IntelToolbar{Sidebar,Agent,Action}View`)
  mirrors the AS `ChatToolbarDelegate` layout — sidebar toggle (leading), centered
  `AgentPill`, settings/new-chat (trailing) — **without** dragging in the heavy
  AS `createChatPanel` / `windowWillClose` path (BackgroundTaskManager /
  ModelRuntime / ServerConfigurationStore are amputated). Delegate retained
  per-window in `toolbarDelegates` (NSToolbar holds its delegate weakly).
- **`ChatWindowState.swift` (Intel `#else`) — agent data wired.** `agents` now
  seeds from `AgentManager` and **live-observes `$agents`** (Combine cancellable)
  so creates/deletes/renames in Settings → Agents reflect in the pill without a
  relaunch. Added faithful **`switchAgent(to:)`** (stop TTS → save turns → repoint
  agentId/theme/caches → `session.reset(for:)` → refresh). `cleanup()` cancels the
  cancellable. Second init now seeds `agentId` from the active agent too. Added a
  `TTSService.stop()` no-op to the Intel audio stub.

**Behavior — selecting an agent actually drives the chat** (the bug Renée caught
post-UI: the pill switched identity but conversations were unaffected):

- **`AgentManager.effective{SystemPrompt,Model,Temperature,MaxTokens}`
  (`IntelManagerConformers.swift`)** were hollow stubs (`""` / `nil` / ignored the
  agent). Now **mirror upstream** (`Managers/AgentManager.swift`, excluded): custom
  agents use their own `Agent` fields; the Default agent (and any unknown id) defers
  to the global `ChatConfiguration` persisted by Settings → Configuration
  (`ChatConfigurationStore`). New `resolvedAgent(_:)` helper encodes the
  "custom-vs-Default" branch.
- **`SystemPromptComposer.composeChatContext` (Intel stub,
  `IntelDataConformers.swift`)** returned an **empty `ComposedContext()`** → the
  send path's `var sys = context.prompt` was always `""`. Now returns the agent's
  **effective system prompt** (`await MainActor.run { … }`). The full preflight /
  memory / tool-resolution pipeline stays amputated; only the one thing that
  matters here — the persona — is honored. (`composePreviewContext` deliberately
  left as the empty stub: it only feeds the cosmetic context-budget popover and is
  also called from the test target where main-actor isolation isn't guaranteed, so
  `MainActor.assumeIsolated` would be a crash risk.)
- **`ChatSessionsManager.sessions(for:)` (Intel stub)** ignored `agentId` and
  returned every session. Now **filters by agent like upstream**: Default (or `nil`)
  is the see-all lens; a custom agent returns only its own chats. This fixed the
  sidebar showing a zoo of every agent's history while a custom agent was active.

### Click-through results (Renée)

- ✅ Centered pill shows the active agent (avatar + name), dropdown lists all
  agents with a ✓ on the current one, gear + "Manage Agents…" open Settings → Agents.
- ✅ Selecting a custom agent applies its **system prompt** — test agent "Uga Buga"
  ("You strong caveman") replied *"Ugh! Me strong caveman! What you want?"* 🦖
- ✅ Sidebar scopes to the active agent (custom = its chats; Default = all).
- ✅ Live update: agents created in Settings appear in the pill without relaunch.

### Lessons / notes

- **Two filter layers in the chat sidebar, often conflated:** the **agent scope**
  (`sessions(for: agentId)`, applied *upstream* of the sidebar) vs the **All/Chat
  toggle** (a `SessionSource` *type* filter applied *inside* the sidebar). On Intel
  every session is `.chat` (plugins/schedules/watchers amputated), so the All/Chat
  toggle is near-cosmetic; the agent scope is the meaningful one.
- **Orphaned old sessions:** chats created *before* this commit were tagged with the
  old throwaway `agentId`, so they only surface under Default's see-all lens — not a
  regression. A one-time re-tag-to-Default migration is possible but optional.
- **Faithful-but-scoped wins again:** the AS toolbar *machinery* (delegate + item
  views) was separable from the amputated AS *window-lifecycle* path. Mirroring just
  the delegate into the Intel block (rather than un-body-swapping the whole AS
  `createWindow`) kept the cascade to zero AS-code changes and ~3 surface gaps.

### Remaining M12

- **Gap 3 (runtime tools)** — next. Un-exclude `ToolRegistry` + `FolderToolManager`,
  selectively gate the amputated `DB*Tool` / sandbox / capability registrations.
- **Gap 2 (folder context)** — falls out of Gap 3; wire `DirectoryPickerService`.

---

## M12 Gap 2 + Gap 3 — Folder Picker + Runtime Tools (CLOSURE, 2026-06-03)

Commits: `e6f63f9f` (part 1 — foundation), `ef05b435` (part 2 — wiring). The
Intel chat now genuinely reads/writes/searches files and runs shell commands in
a chosen working folder, with proper tool-call cards. **Gap 2 and Gap 3 are one
feature** (folder tools are folder-scoped — they only exist once a folder is
attached).

### The headline finding (Renée's catch)

The agent tool-loop in `ChatView` (send `toolSpecs` → execute
`ToolRegistry.shared.execute` → loop) is **shared, un-stubbed code** — it always
worked. What was missing was the **engine wiring**: the hand-rolled Intel DeepSeek
client `CloudChatEngine` **never sent `tools` to DeepSeek** and the
`StreamingToolHint` decoder was a hollow stub. So every "tool use" was the model
*role-playing* from the prompt (it knew tool names from the folder guide but had
no callable functions). Renée spotted this — "isn't it just copying the original +
adjusting for Intel?" — which reframed the hunt from "why won't the model call
tools" to "is the engine even offering them." It wasn't.

### What shipped

**Foundation (part 1):** un-excluded `Tools/OsaurusTool.swift`,
`Tools/ToolEnvelope.swift`, `Tools/ToolErrorEnvelope.swift`,
`Folder/FolderTools.swift` (the 6 file/shell + 3 git tools, Darwin+Foundation,
clean). Reshaped the Intel `Tool`/`ToolFunction` model to carry JSON-Schema
`parameters` (the mirror had dropped them → schema-less tools). Stubbed
`LiveExecSink` (real one imports amputated Containerization) + `diagnosticWarnings`
so `shell_run` runs and collects output, minus only the live mid-run terminal
streaming.

**Engine-side tool loop (part 2, the core fix) — `CloudChatEngine.streamChat`:**
rewrote as a real agent loop — sends OpenAI `tools` + `tool_choice` (params via
`JSONValue.anyValue`), parses streamed `delta.tool_calls`, executes each via
`ToolRegistry`, yields a "done" sentinel for the card, appends assistant
tool-call + tool-result messages, and continuation-loops until the final answer
(max 12 rounds). Also fixed the message encoder to include `tool_calls` /
`tool_call_id` (it was dropping both).

**`StreamingToolHint`:** implemented the real encode/decode sentinel protocol
(ESC-tagged prefixes) so `ChatView`'s `decodeDone`/`decode` paths turn the
engine's tool events into cards + result turns.

**Registry + context:** Intel `ToolRegistry` got real `register`/`unregister`/
`execute` dispatch + `openAISpecs()` (was canned text + `[]`).
`SystemPromptComposer.composeChatContext` (Intel) now emits the registered folder
tools AND the real `## Working Directory` framing
(`SystemPromptTemplates.folderContext`, NOT excluded) + a firm tool-use directive.

**Folder picker (Gap 2):** un-excluded `FolderContextService` + `FolderToolManager`
+ `FolderPluginHints`. **The silent-failure bug:** `setFolder` minted a
`.withSecurityScope` bookmark, which **throws without the App Sandbox entitlement**
— and the Intel app isn't sandboxed — so the `catch` swallowed it and dropped the
folder (chip stayed empty, no tools). Gated the bookmark path behind
`#if !OSAURUS_INTEL`; the non-sandboxed app attaches the folder directly.

**Rendering (Intel `BlockMemoizer` + tool-call card):** the simplified Intel block
builder never produced `.toolCallGroup` blocks (no cards) and rendered `.tool`-role
turns as paragraphs (raw result JSON dumped into the chat). Fixed: build tool-call
blocks from `turn.toolCalls`, skip `.tool` turns, group consecutive assistant+tool
turns under one header. And `NativeToolCallGroupView` had `applyResultOrLiveState`
gated behind `#if !OSAURUS_INTEL`, so cards showed args but no result — un-gated it
(only the `LiveExecRegistry` live-terminal subscription stays gated).

### Click-through results (Renée, with "Uga Buga" caveman agent 🦖)

- ✅ Folder chip → NSOpenPanel → folder attaches (chip shows `04_Cooking`)
- ✅ `file_tree` / `file_read` / `shell_run` execute for real (byte-exact `ls -la`)
- ✅ `file_write` actually creates `hello.md` / `uga.md` on disk
- ✅ Tool-call cards render with ARGUMENTS **and** RESULT inside (expandable);
  no raw JSON leaks into the chat
- ✅ Settings → Tools "Available (0)" is **correct** — that tab is for
  plugin/provider tools; folder tools are ephemeral and surface in-chat

### Lessons

- **DeepSeek V4 Flash is an inconsistent tool-caller** — but that was a red
  herring masking the real bug (tools never sent). Once the engine offered real
  function specs, Flash called them reliably.
- **`.withSecurityScope` bookmarks require the sandbox entitlement** and throw
  silently otherwise — a classic non-sandboxed-fork trap.
- **The result lives in the card, not a chat bubble** — skipping `.tool`-role
  turns in the block builder is the right call; the result rides on the
  assistant turn's `toolResults` into the `ToolCallItem`.

---

## M12 follow-up — RemoteProviderEditSheet restored (CLOSURE, 2026-06-03, commit `83c1083a`)

Renée found that Settings → Providers → edit (✏️) showed the "Apple Silicon only"
placeholder. The entire 2500-line `RemoteProviderEditSheet` had been body-swapped
during M11 — but editing a provider's name / base URL / API key / headers / model
list needs **zero** Apple Silicon (pure config + keychain). Un-body-swapped it (it
imports only AppKit + SwiftUI, no amputated refs). The one surface gap was
`testConnection` — the upstream one pulls in `RemoteProviderService` + OAuth +
Anthropic helpers, so added a pragmatic Intel mirror doing the OpenAI-compatible
`GET /models` probe (covers DeepSeek), returning discovered model ids, so the
sheet's Test → Save flow works. Verified: edit form opens, saves, Test probes.

---

## M12 follow-up — Menu-bar status card + chat-window lifecycle (CLOSURE, 2026-06-03, commit `76b72a6a`)

Renée noticed the Intel menu-bar popover was a bare "Osaurus (Intel) / Quit"
card vs the production card (icon, version, server URL, CPU/RAM, Ask AI, quick
actions). Restoring it surfaced — and fixed — two latent chat-window crashes.

### The card — `IntelStatusPanelView` (AppDelegate.swift)

A self-contained, theme-aware status panel mirroring the production card's look:
app icon (→ Server settings), **Osaurus** + version + `Intel` badge + green
running dot, server URL `127.0.0.1:1338` + copy, **live CPU/RAM gauges**
(`SystemMonitorService`, NOT excluded), and **Ask AI / ⚙️ Settings / ❓ Docs /
⏻ Quit**. Theme-driven (`ThemeManager.currentTheme`), reuses the real
`CircularIconButton`, compact themed `Ask AI` accent pill.

**Why not un-body-swap the upstream `StatusPanelView`?** It's built for
local-server lifecycle (start/stop/restart, editable port, voice/VAD, model
status) — un-body-swapping surfaced **47 errors** of inapplicable machinery
(`server.lastErrorMessage` setter, settable `port`, `VADService`, `StatusBadge`,
model status). Per the ">5-cascade → STOP" rule, built a focused Intel card
instead. Skipped: voice/mic toggle (amputated), server start/stop (Intel server
is always-on via env-var key).

### Visual polish (Renée's round-2 feedback)

- **Theme background** — the first cut used default chrome (looked transparent /
  square). Now `theme.primaryBackground` + a bounded `frame(height: 184)` (the
  background's `ignoresSafeArea()` was stretching the popover tall).
- **Compact themed Ask AI** — was a giant blue `.borderedProminent`; now a small
  `theme.accentColor` gradient pill like the upstream `AskAIButton`.
- **Docs button** — added the `?` → `https://docs.osaurus.ai/`.

### Two chat-window lifecycle crashes (from Renée's crash report)

`EXC_BAD_ACCESS` in `ChatWindowManager.showWindow(id:)` via "Ask AI". Root cause
chain:

1. **Dangling window.** The Intel chat window had **no `NSWindowDelegate`**, so
   closing it via the traffic-light released the `NSWindow`
   (`isReleasedWhenClosed = true`) while `windows`/`nsWindows` kept stale
   references → "Ask AI" / dock-reopen poked freed memory. **Fix:**
   `ChatWindowManager` (Intel) is now the `NSWindowDelegate` —
   `windowWillClose` purges bookkeeping, `windowDidBecomeKey` tracks
   `lastFocusedWindowId`.
2. **Double-free.** Adding the delegate then exposed a second crash: closing the
   window with `isReleasedWhenClosed = true` released it AND our `windowWillClose`
   dropped the dict's strong ref → double-free mid-close (red button crashed).
   **Fix:** `isReleasedWhenClosed = false` — the manager's dict is the sole
   strong owner; removing it in `windowWillClose` is the single safe release.
3. **Popover teardown reentrancy.** `openChatFromStatusPanel` defers the window
   work past `performClose` (a `DispatchQueue.main.async` tick) so it doesn't run
   while the popover's SwiftUI host is tearing down.

This trio makes Intel chat-window lifecycle solid — no dangling refs, no
double-free, clean dock-reopen. (Bugs 1 + 2 also affected dock reopen after
closing a chat window — hit incidentally via the menu bar.)

### Verified (Renée)

✅ Card themed + correct compact shape · ✅ red close button (no crash) · ✅ Ask
AI opens/focuses chat · ✅ dock reopen after close · ✅ Settings / Docs / Quit.

---

## M12 follow-up — Remote MCP providers (CLOSURE, 2026-06-03, commit `1a627cf9`)

Tools → Remote showed "Apple Silicon only", but MCP runs on Intel (the bridge
serves on :1338). Restored the real remote-MCP-provider subsystem.

- Un-body-swapped `Views/Settings/ProvidersView.swift` (the MCP UI; AppKit+SwiftUI).
- Un-excluded `Managers/MCPProviderManager.swift` + `Tools/MCPProviderTool.swift`
  (both MCP SDK + Foundation). Removed the hollow Intel MCPProviderManager stub +
  its duplicate `mcpProviderStatusChanged` mirror.
- **Gated the stdio-via-sandbox transport** (`SandboxManager`/`SandboxStdioRunner`,
  ~3 spots + the `sandboxStdioRunners` map) behind `#if !OSAURUS_INTEL`: HTTP
  remote MCP works for real; a sandbox/stdio provider throws `.sandboxUnavailable`.
- Added `ToolRegistry.registerMCPTool` to the Intel registry; `testConnection`
  added to the Intel manager earlier (provider-edit follow-up) does the real
  OpenAI-style `/models` probe.
- **Verified (Renée): GitHub MCP connected (43 tools); agent called
  `github_get_me` + `github_search_repositories` and used the results.**

## M12 follow-up — Agent Capabilities tab + MCP auto-reconnect (CLOSURE, 2026-06-03, commit `2d6e5499`)

The per-agent Capabilities sub-tab showed "Apple Silicon only" — but the agent
genuinely uses tools on Intel. Full functional restore.

- Un-body-swapped `AgentCapabilityManagerView`. Intel `AgentManager` got real
  per-agent capability persistence: `effectiveToolSelectionMode` (now
  non-optional, mirrors upstream), `effectiveEnabledTool/SkillNames`,
  `seedEnabledCapabilitiesIfNeeded`, `updateEnabledTool/SkillNames`,
  `updateToolSelectionMode`. Custom agents persist to disk; Default → global
  ChatConfiguration.
- Intel `ToolRegistry` got `builtInToolNames`/`runtimeManagedToolNames`/
  `isMCPTool`/`isPluginTool`/`isSandboxTool`/`groupName` (MCP tools bucket by
  `MCPProviderTool.providerName`). Added `.agentUpdated` notification.
- **`composeChatContext` now HONORS the picker**: Manual mode restricts the
  agent to its enabled allowlist; Auto sends everything registered.
- **MCP auto-reconnect**: `AppDelegate` now calls
  `MCPProviderManager.shared.connectEnabledProviders()` at startup (the prod app
  does this; the wiring was missing on Intel — providers stayed disconnected
  after relaunch so their tools never registered). This was the "GitHub tools
  missing from the picker" fix.
- **Data cleanup:** the orphaned seeded skills (`osaurus-fetch/search/time`,
  `vectura`) in `~/.osaurus-intel/skills/` were copied from `~/.osaurus` during
  the M11.A.2 seed; they reference amputated plugins. Removed them (kept
  `writing-reviewer`, a pure-instruction skill). Production `~/.osaurus`
  untouched. No code change.
- **Verified (Renée): GitHub's 43 tools show in the picker, grouped under
  "GitHub"; toggles persist; Manual mode bites.**

---

## M13 — Group C tabs (the 6 greyed tabs)

### Survey (2026-06-03) — amputated vs restorable

| Tab | Backing | Blocker | Verdict |
|-----|---------|---------|---------|
| **Insights** | `InsightsService` | none (Foundation+Combine) | ✅ restored |
| **Memory** | `MemoryDatabase`+`MemoryService` | DB is SQLCipher (ok) but recall = MLX/VecturaKit embeddings; recording = `DistillationCoordinator` | 🟡 deferred (Renée uses vault + renee.rag; Osaurus memory stays off) |
| **Schedules** | full background-task chain | none hardware — but DEEP (see scope below) | 🟡 scoped, not built |
| **Models** | `ModelManager` | `import MLXLLM` (no local runtime) | 🔴 leave greyed |
| **Voice** | `SpeechService`/`TTSService` | `import FluidAudio` | 🔴 leave greyed |
| **Sandbox** | `SandboxManager` | `import Containerization` (macOS 26 + AS) | 🔴 leave greyed |

**Key lesson:** "amputated" only ever meant the 4 hardware/OS-bound packages
(MLX, FluidAudio, Containerization, VecturaKit). Foundation/Combine/SwiftUI/
AppKit/SQLCipher are all available on Intel + macOS Sequoia (incl. under OCLP) —
the running app proves it. A manager importing "only Foundation+Combine" is a
green flag.

### M13 Insights (CLOSURE, 2026-06-03, commit `1cf7fa5a`)

- Un-body-swapped `Views/Insights/InsightsView.swift`; un-excluded
  `Managers/InsightsService.swift` (brought `MethodFilter`).
- **Instrumented `HTTPHandler.sendResponse`** to log every non-streaming request
  (health/models/MCP/router/non-stream chat) to `InsightsService` with
  method/path/status/duration (added `requestStartedAt` to `RequestState`). SSE
  streaming chat bypasses this sink; in-app chat uses `CloudChatEngine` directly,
  so Insights reflects external API/MCP clients hitting :1338 (correct
  server-analytics semantics).
- `ManagementTab.isAvailableOnIntel`: `.insights` → true (un-greyed). Memory +
  Schedules remain gated.
- **Verified (Renée): tab renders; `curl /health` + `/models` logged 200 + duration.**

### Schedules — BUILT ✅ (M13, Renée 2026-06-04, tag `m13-schedules` @ 0b3a5d2a)

**The deepest Group C item, restored end-to-end.** Scheduled agents fire
headless through the existing cloud pipeline (`NextRunScheduler` cron loop →
`ScheduleManager`/`SchedulerDatabase` → `TaskDispatcher` → `BackgroundTaskManager.dispatchChat`
→ `ChatSession.send` → `composeChatContext` → `CloudChatEngine`). Verified by
Renée on Rosy: schedules fire on time, multi-round tool-calling works (GitHub
MCP, 43 tools, 6 rounds), folder-scoped runs list/read local files (Caldo Verde
from `04_Cooking`).

**The trial last session was 251 → 75; this time recon paid off: 69 → 0 in a
SINGLE triage round.** Core restore (commit `919a4f54`):

- **Un-excluded the clean cluster** (`Package.swift`): `ScheduleManager`,
  `TaskDispatcher`, `NextRunScheduler`, `BackgroundTaskManager`,
  `SchedulerDatabase`, `BackgroundTaskModels`, `DispatchRequest`,
  `ExecutionContext` — all pure Foundation/Combine/SQLCipher.
- **New `IntelScheduleConformers.swift`:** `PluginHostContext` stub (event
  serializers → `"{}"`, `invalidatePreflightCache` → `SessionToolStateStore`),
  plus `TaskEventType` and `StorageMigrationCoordinator` stubs.
- **Removed colliding Intel stubs** (IntelAgentConformers): `ScheduleManager`,
  `SchedulerDatabase`, `ScheduleEditorSheet` + the `schedulesChanged` mirror;
  extended the `ChatHistoryDatabase` conformer with session-reattach no-ops
  (`open`/`findSession`/`loadSession` → nil — Intel has no persisted history DB).
- **`SessionSource` + `ChatSessionData` made `public`** (un-excluded files expose
  them in public API; upstream is public too).
- **`BackgroundTaskManager` gated** the plugin-notify + plugin-tool-seeding blocks
  (`#if !OSAURUS_INTEL` — plugins amputated, `PreflightResult.empty` unavailable).
- **`ChatWindowManager.createWindowForContext`** (delegates to `createWindow`).
- Un-body-swapped `SchedulesView` + `ScheduleEditorSheet`; started
  `NextRunScheduler` at launch (AppDelegate, after MCP auto-connect); un-greyed
  `.schedules`.

**Where reality differed from the 2026-06-03 SCOPE:**
- `TaskEventType` + `StorageMigrationCoordinator` DID need stubs (scope guessed
  they might already exist) — their real homes (`ExternalPlugin.swift`,
  `StorageMigrationOverlay.swift`) are *fully* `#if !OSAURUS_INTEL`, so only the
  stub branches survive on Intel. Added both to `IntelScheduleConformers`.
- `findSession`/`loadSession`/`open` live on **`ChatHistoryDatabase`** (not
  `ChatWindowManager` as the scope guessed) — extended that conformer instead.
- `.empty` was `PreflightResult.empty` in a plugin-only tool-seeding block →
  gated out rather than stubbed.
- One round, not 3–5. Bounded estimate held; recon made it cheap.

**Follow-ups Renée surfaced while testing (all BUILT + verified):**
- **Working-dir pass-through** (in `919a4f54` + ExecutionContext changes): the
  schedule-editor folder picker used `.withSecurityScope` (throws on the
  non-sandboxed Intel app — same M12 bug) → gated. Threaded `folderPath` through
  `DispatchRequest → ExecutionContext`; on Intel it attaches the raw path
  directly (folderBookmark is nil). Without it scheduled runs ignored their dir.
- **Sidebar live-refresh** (`919a4f54`): the Intel `ChatWindowState` never called
  `observeSessionsManager` (AS does) → background/scheduled saves only appeared
  on agent-switch. Wired the `$sessions` subscription.
- **Appear-at-start** (`919a4f54`): `send()` auto-saves a new row only when it
  has to mint a `sessionId`, but dispatched sessions pre-assign one → the early
  save was skipped. `ExecutionContext.start` now saves right after `send()`.
- **Delete-conversation fix** (`672451e2`): (a) the confirmation presented
  through `ThemedAlertCenter` keyed on `@Environment(\.themedAlertScope)` but the
  chat window hosted no `ThemedAlertHost` → dialog never drew → "Delete" no-op'd.
  Scoped each window `.chat(windowId)` + hosted a matching `ThemedAlertHost`.
  (b) The row resurrected because the live session still held the id + turns and
  re-persisted on next send / the synchronous `save()` in `reset()→stop()→
  completeRunCleanup`. Now resets the window to a fresh chat first, deletes after.
- **Toasts** (`bb4e8527`): the ENTIRE toast layer (`ToastContainerView` /
  `ToastWindowController` / `ToastOverlayModifier`) was `#if !OSAURUS_INTEL` —
  `ToastManager.show()` appended to a list nothing rendered. Un-body-swapped the
  file (pure AppKit+SwiftUI) + called `ToastWindowController.shared.setup()` at
  launch (the standalone status-level overlay panel — no WindowGroup needed,
  which suits the minimal Intel AppKit entry).
- **Session persistence across launches** (`d2ee63a2`): upstream persists via the
  excluded `ChatHistoryDatabase` (SQLite); Intel had only an in-memory dict, so
  every relaunch wiped conversations (settings stuck because they had a store).
  Made Intel `ChatTurnData` + `ChatSessionData` `Codable` (hand-rolled
  `ChatTurnData` to skip the transient `preflightCapabilities: Any?`);
  `ChatSessionsManager` now loads on init + writes one JSON per chat to
  `~/.osaurus-intel/sessions/<uuid>.json`, rewriting on mutation, deleting on
  delete. ISO-8601 dates both ends. Scheduled chats persist too.
- **Task-running indicator** (`0b3a5d2a`): NotchView is amputated, so new Intel
  surface. `IntelTaskBanner` (@MainActor ObservableObject) holds the current/recent
  task; `BackgroundTaskManager` (Intel-gated) raises it + an info toast titled
  "<AgentName> started a task" (8s) on a non-`.chat` start, flips it to
  Finished/Failed on completion. `IntelStatusPanelView` renders a persistent card
  row (spinner → ✓/⚠), tappable to open that conversation (loaded from the
  persisted store) + clear, or × to dismiss; card grows 184→234 when shown.

**Known limitation (not built):** clicking a *running* task's row/sidebar entry
opens the saved SNAPSHOT, not a live-streaming view — true live-view-while-running
needs window↔task-session binding (the Intel `ChatWindowState.executionContext`
init ignores the context). The run completes + fills the row regardless.

### Group C — final state (2026-06-04)
- ✅ **Insights** (`1cf7fa5a`) · ✅ **Schedules** (`m13-schedules`)
- 🟡 **Memory** — deferred (Renée uses the vault + renee.rag; Osaurus memory
  stays off). Only worth a cloud-distillation + dumb-recall build later.
- 🔴 **Models / Voice / Sandbox** — stay amputated (hardware blockers: MLX /
  FluidAudio / Containerization). Functionally, the Intel fork's tabs are now as
  complete as they can be without the amputated subsystems.

### Tags laid
`m11-settings-complete` (57208c08) · `m12-chat-complete` (913de45a) ·
`m13-schedules` (0b3a5d2a). (Insights shipped under M13 at `1cf7fa5a`, no separate
tag.)

---

## Post-Schedules sweep — Watchers, Sparkle, Plugins (2026-06-04)

Renée tested the freshly-built tabs and surfaced four gaps. Three fixed, the
fourth (plugin execution) scoped + deferred.

### Watchers — BUILT ✅ (`35147f96`, + folder-picker `1e1386e4`)

Same shape as Schedules: the real `WatcherManager` was **excluded with a no-op
Intel stub active**, so "Create Watcher" did nothing — never persisted, appeared,
or fired. Two-part fix:
- Folder picker (`1e1386e4`): `WatchersView.selectWatchFolder` used
  `.withSecurityScope` (throws on the non-sandboxed Intel app) → gated, store raw
  path + nil bookmark. (Necessary but not sufficient — see below.)
- Manager (`35147f96`): un-exclude `Managers/WatcherManager.swift` (FSEvents-based,
  pure CoreServices/Foundation — `Watcher`/`WatcherStore`/`TaskDispatcher`/
  `DispatchRequest` all already compiled, **zero amputated deps**). Removed the
  Intel stub + `watchersChanged` mirror. Instantiate `WatcherManager.shared` at
  launch (init → `startAllEnabledWatchers`). `resolveWatchPath` falls back to the
  raw path when the bookmark is nil, and the on-change dispatch carries
  `folderPath` (attached by the M13 ExecutionContext fix), so it works end-to-end:
  change → FSEvents → TaskDispatcher → agent run (+ task toast + menu-bar card).
  **Verified (Renée): card appears; a file change fires file_tree/file_read.**

### Sparkle auto-update — DISCONNECTED on Intel ✅ (`014d98da`)

The official appcast ships Apple-Silicon builds; once its version surpasses the
fork's, an auto-check could download + REPLACE the hand-built Intel app.
`UpdaterService` made inert on Intel three ways: `startingUpdater: false` (no auto
cycle), `feedURLString → nil` (no appcast), both check methods no-op (manual
"Check for Updates" → an info toast saying updates are pinned off), beta-channel
`resetUpdateCycle` gated out. **Verified (Renée): toast appears, no checks.**

### Plugins — M9 capability-aware loading

Found the M9 design doc (`Osaurus_Intel_Plugin_Capability_Loading.md`); **Phase 1
already shipped** (`HostCapability` + `PluginCompatibility` exist, MLX/vector/voice
gated `#if !OSAURUS_INTEL`). The hard reality, confirmed: **`OsaurusRepository`'s
`CPUArch` enum only models `.arm64`** — the registry has zero x86_64 artifacts, so
**no official plugin can ever run on Intel** (Rosetta only goes x86→ARM, never
ARM→x86). Renée chose: ship Browse + honest gating now; defer execution to a fresh
session.

- **Phase A — Browse ✅** (`d5567d15`): the git registry fetcher
  (`CentralRepositoryManager`) + `PluginSpec` live in the already-linked
  `OsaurusRepository` package (plain Foundation), so Browse works without the
  amputated execution host. Rewrote the Intel `PluginRepositoryService.refresh()`
  stub to `CentralRepositoryManager.shared.refresh()` + `listAllSpecs()`, mapping
  each spec → the Intel `PluginState` (version converted; capabilities skipped;
  nothing ever installed → all land in Browse). **Verified: Browse(20) populates
  with the real registry.**
- **Phase B — honest gating ✅** (`808974ba`): `PluginState.requiresAppleSilicon`
  computed in the mapping ("no x86_64 artifact" → true for all today, future-proof).
  PluginsView: browse cards show an "Apple Silicon" capsule; detail view replaces
  Install with a disabled "Apple Silicon required" pill + tooltip. Gated
  `#if OSAURUS_INTEL` via a computed bool so the shared view compiles on AS.
  **Verified (Renée): badges + disabled install render.**

### Plugins Phase C/D — ✅ BUILT (2026-06-04, slim-host architecture)

**Done — but NOT via the full restore scoped below.** When the cascade was
measured honestly it came to **~41 amputated touchpoints** (PluginHostAPI:
`ToolRegistry ×10`, `AgentManager ×7`, `EmbeddingService ×3`, `ChatEngine ×2`,
`SandboxToolRegistrar ×2`, `MLX ×2`, …; real PluginManager: `AgentManager ×3`,
`SkillManager ×4`, `ToolRegistry ×4`) **+ 4 type collisions + 3 more file
un-exclusions** — 8× over the revert threshold, and most restored callbacks
(embed/MLX/inference/sandbox) are dead on Intel anyway. So Renée chose the
**slim self-contained Intel host** instead. The full-restore scope is kept
below for the record but is **not the path taken**.

**What shipped (commits `93c42cb0` Phase C, `aa46d50b` Phase D):**
- **`Models/Chat/IntelConformers/IntelPluginExecution.swift`** (NEW, `#if
  OSAURUS_INTEL`): a private ABI v6 mirror (`osr_host_api` / `osr_plugin_api` +
  all typealiases — unique to the Intel build since `ExternalPlugin`'s copy is
  `#if !OSAURUS_INTEL`); a slim host-API table with **real** callbacks
  (log, log_structured, free_string, config_get/set/delete [file-backed under
  `Tools/.intel-plugin-config.json`], file_read [base64], http_request [sync
  URLSession, matches the production request/response contract]) and **honest
  `not_supported` envelopes** for the amputated ones (db_exec/query, dispatch*,
  complete*, embed, list_models, list_active_tasks, get_active_agent_id) + no-op
  voids — every slot non-null so no plugin can null-deref. `buildIntelHostAPI()`
  owns the host-table pointer for the plugin's lifetime. `IntelLoadedPlugin`
  (handle+ctx+host-table, serialized `invoke` on a per-plugin queue, `teardown`).
  `IntelPluginLoader.load` (dlopen `RTLD_NOW|RTLD_LOCAL` → `osaurus_plugin_entry_v2`
  → init → get_manifest → parse `capabilities.tools[].id`) + `findDylib`.
- **`Managers/Plugin/PluginManager.swift`** (Intel `#else` branch): `loadAll`
  now scans **`~/.osaurus-intel/Tools`** via `OsaurusPaths.root()` (FIXED the
  data-isolation bug — was hardcoded to production `~/.osaurus/Tools`),
  resets+tears down live handles on every rescan (also fixed the pre-existing
  append-duplication), and `loadNative()` dlopens compatible/degraded plugins
  into `nativePlugins[id]`. Public API: `invoke(pluginId:toolId:payload:type:)`,
  `isNativelyLoaded(pluginId:)`, `nativeToolIds(pluginId:)`. `runNativeSelfTest()`
  invokes each live plugin's first tool, gated behind
  `OSAURUS_INTEL_PLUGIN_SELFTEST`. All Phase C/D diagnostics use `NSLog` (flush
  immediately; `print()` to a redirected file is buffered + lost on SIGTERM).
- **`AppDelegate.swift`**: when `OSAURUS_INTEL_PLUGIN_SELFTEST` is set, runs
  `loadAll()` at launch so the proof fires headless (no Plugins-tab open needed).
- **`intel-plugins/hello/`** (NEW, outside the SwiftPM target so it isn't
  compiled into the app): `hello.c` (exports `osaurus_plugin_entry_v2`,
  implements the required API, calls `host->log`, returns a JSON greeting),
  `manifest.json`, `build.sh` (`clang -arch x86_64 -dynamiclib` + ad-hoc
  codesign + install to `~/.osaurus-intel/Tools/hello-intel/`). Built `.dylib`
  gitignored.

**Verified end-to-end (x86_64 build, Rosetta on the dev Mac):**
```
loaded native plugin 'hello-intel' — tools: ["hello"]
self-test ✅ hello-intel/hello → {"ok":true,"tool":"hello","message":
  "Hello from a native x86_64 plugin running on the Osaurus Intel fork!",
  "payload_bytes":2}
```
`payload_bytes:2` confirms the `{}` arg arrived; the host `log` callback
round-tripped. dlopen → entry_v2 → init → get_manifest → invoke all confirmed.

**Reproduce:** `intel-plugins/hello/build.sh` then launch with
`OSAURUS_INTEL_PLUGIN_SELFTEST=1` (watch Console/terminal), or open the Plugins
tab (loadAll fires on appear). No official arm64 plugin can ever run (Rosetta is
one-way x86→ARM) — only natively-built x86_64 plugins.

### Plugins Phase E — ✅ agent tool bridge + 3 real plugins (2026-06-05)

**Plugin tools are now callable from chat** — the "exposure gap" is closed,
*without* MCP. The Intel `ToolRegistry` mirror (IntelStubConformers) is fully
real: `register()` → `openAISpecs()` (sent to the model via `ComposedContext.tools`)
→ `execute()` (dispatches the call). It already carries GitHub's MCP tools +
folder tools into the agent loop, so plugin tools register the same way.

**What shipped (commit `000bad85`):**
- **`IntelPluginTool: OsaurusTool`** (IntelPluginExecution.swift): wraps a plugin
  tool; `execute()` routes to `PluginManager.nativeHandle(for:).invoke` **off the
  main actor** (DispatchQueue.global + continuation) so a network call doesn't
  freeze the UI. `parseToolSpecs` decodes full `{id, description, parameters}`
  (JSON-Schema) from the manifest so the model gets a real arg schema.
- **PluginManager (Intel):** `loadNative` registers each tool into
  `ToolRegistry.shared`; `loadAll` reset unregisters the prior run's tool names
  first. `nativeHandle(for:)` accessor. `OSAURUS_INTEL_PLUGIN_TESTCALL='tool|{json}'`
  invokes a tool through `ToolRegistry.execute` (the real agent path) for verification.
- **Three native x86_64 plugins** (`intel-plugins/`, `build-all.sh` →
  `~/.osaurus-intel/Tools/<id>/`, `.dylib` gitignored):
  - **time** → `get_current_time` (local+UTC ISO-8601, tz, epoch; no host calls).
  - **fetch** → `fetch(url)` (HTTP GET via `host->http_request`, returns
    `{status,body,headers}`, 100 KB cap).
  - **search** → `web_search(query)` (DuckDuckGo lite, **no API key**, parses top
    results → `[{title,url,snippet}]`; handles direct + `uddg=` hrefs).
  - **common/osr_jsonutil.h**: JSON get/escape, URL encode/decode, HTML strip +
    entity decode + whitespace collapse.

**Verified** end-to-end through `ToolRegistry.execute` (the agent path), not just
the loader: `get_current_time` → real clock; `fetch(example.com)` → 200 + body;
`web_search("weather paris today")` → real AccuWeather/easeWeather results with
snippets. In chat: Auto mode sends them to the model automatically; Manual mode
exposes them in the capability picker.

**Surfacing (added 2026-06-05, commit `749fe4a2`):** native plugins now show in
the **Plugins → Installed** tab under a "Native — this fork" section (name,
version, tool list, per-card gear → config sheet for plugins with settings), via
`PluginManager.nativelyLoadedPlugins()` (loadedPlugins filtered to those with a
live dylib handle). Verified through the AX tree: all 5 (time/fetch/search/memo/
hello) render with their tools; the gear opens the config sheet.

**Capability + Tools-tab surfacing (commit `d45e6d26`):** native plugin tools
were registered in ToolRegistry but `source(forTool:)` classified them as
`.builtIn`, which `AgentCapabilityManagerView` FILTERS OUT at row emission — so
they never showed in the picker and (in Manual mode) were excluded from the
model. Fixed: Intel ToolRegistry now classifies them as real plugin tools
(`registerPluginTool(_:group:)` → `isPluginTool`/`groupName` return the plugin
display name), so they render as selectable per-plugin groups (Memo, Search,
Time, Fetch, Hello Intel). `loadNative` registers via `registerPluginTool`.
Also: ToolsManagerView gained a "Plugin Tools (native)" section; the
**Sandbox Plugin Creator** built-in skill is filtered out of `Skill.builtInSkills`
on Intel (sandbox amputated → dead capability). Card polish (`4ec373a4`):
`NativePluginCard` (accent outline, Loaded badge, tool count, `…` menu with View
Details/Settings/Reveal in Finder, tap → `IntelNativePluginDetailView`).
*NOTE:* for an agent that has customized its tool allowlist (Manual mode), the
user must tick the new plugin groups in Capabilities to enable them; agents with
an un-customized (nil) allowlist get them automatically.

**UI polish (commits `0a0cbdad`, `913ffbe6`):** the native card/detail/config/
Tools-tab views were switched from system colors to `@Environment(\.theme)`
tokens (were invisible under a light theme), and the card detail now renders
**inline** (back button) instead of a dark `.sheet`. Tools tab: `NativeToolGroupCard`
is collapsible with a real **per-tool on/off toggle** — the Intel ToolRegistry
gained a `disabledToolNames` set (`setEnabled` was a no-op; now `openAISpecs()`
filters disabled tools, so both native AND GitHub toggles actually work).

**Still optional (NOT done):** a UI "Run tool" button for ad-hoc invocation
(tools are callable from chat via `openAISpecs()`); true MCP `tools/call`
exposure for external MCP clients (the in-app agent path doesn't need it);
persisting the disabled-tools set across launches (currently session-scoped).

### Plugins Phase F — ✅ host-callback upgrades (2026-06-05)

Promoted five slim-host `not_supported` stubs to real Intel subsystems. **None
via Path A's file restore** — each just wires a callback to a mirror that
already compiles. The dead question per callback is "does its backing subsystem
live on Intel?": BackgroundTaskManager ✅, CloudChatEngine ✅, sqlite ✅;
EmbeddingService ❌ (MLX), HTTP server ❌ (so `embed` + `handle_route` stay dead).

Commits `a7fcc442` (worth-it: db/dispatch/instructions), `c1c10303` (complete),
`d349a25c` (config UI).

- **db_exec / db_query → per-plugin SQLite** (`import OsaurusSQLCipher`). A
  thread-local current-plugin-id, set around `invoke` (callbacks run sync on that
  thread), scopes the DB file `~/.osaurus-intel/Tools/<id>/plugin.db` AND config
  keys. Positional + named params; rows/rows_affected/last_insert_rowid JSON.
- **dispatch / task_status → TaskDispatcher/BackgroundTaskManager.** A plugin
  spawns a background agent task (under `Agent.defaultId` — the gate refuses a nil
  agentId; that was the first-cut bug). Integrates with the M13 task indicator.
  **⚠️ CAVEAT (2026-06-05, commit `6afb7176`):** `BackgroundTaskManager.dispatchChat`
  runs the task as an unstructured `Task { @MainActor in … }` — i.e. on the SAME
  main actor the live chat uses. A plugin dispatching **mid-chat** therefore
  contends with and FREEZES the active conversation (Schedules/Watchers are fine —
  they fire when idle). The Intel chat runtime is `@MainActor` end-to-end, so
  there's no cheap off-main path. `run_background` was removed from the memo demo
  for this reason; the dispatch callback stays wired but plugins should not call
  it during an active chat. Also fixed a leak: `intelDispatch` now calls
  `releaseEventsForDispatch` (held events were never flushed — `heldTaskEvents`
  grew unbounded once Intel plugin dispatch started setting `sourcePluginId`).
  A truly concurrent-safe background runtime would be its own milestone.
- **complete → CloudChatEngine** (the `ChatEngine` actor, DeepSeek/remote, reads
  `DEEPSEEK_API_KEY`). A plugin does its own LLM step in one tool call.
- **instructions:** manifest top-level `instructions` appended to the system
  prompt when any of the plugin's tools are active (`composeChatContext`).
- **on_config_changed + config UI:** manifest `secrets[]` →
  `IntelPluginConfigField`; `IntelPluginConfigView` (gear button in the Plugins
  header, Intel-only) lists configurable native plugins with editable fields;
  `setConfig` persists (scoped) + calls the plugin's `on_config_changed`.
- **Blocking bridge** (`IntelBox` + semaphore) runs async/MainActor work from the
  sync C trampolines — safe because plugin callbacks run off the main actor
  (`IntelPluginTool` invokes on a background queue).
- **Still `not_supported`/no-op:** embed (MLX gone), handle_route/web (no HTTP
  server), complete_stream, list_active_tasks/send_draft/interrupt, registry
  install (arm64 only).

**memo plugin** (`intel-plugins/memo`) demonstrates db + dispatch + instructions
+ complete (memo_save/list/clear, run_background, ask_model). **search** gained a
real `region` config consumer. Test hooks: `OSAURUS_INTEL_PLUGIN_TESTCALL`,
`OSAURUS_INTEL_PLUGIN_SETCONFIG`.

**Verified** (all through `ToolRegistry.execute`, the agent path): memo persisted
across a relaunch; run_background → `{id,status:running}`; ask_model → `PONG`;
setConfig(region=br-pt) → search returned pt-BR results.

---

#### Original full-restore SCOPE (NOT taken — kept for the record)

**The execution host restore. Bigger than Schedules; its own milestone.** Goal:
let a *natively x86_64-built* plugin actually load + run (no official plugin will
— they're arm64). The M9 doc's Phases 2–4.

- **Un-exclude:** `Services/Plugin/PluginHostAPI.swift` (**3,516 lines** — the C-ABI
  host: config/db/http/log callbacks; imports only Foundation+os; ~9 amputated
  touchpoints to gate: `EmbeddingService` ×3, `SandboxToolRegistrar` ×2, `MLX`/
  `MLXService` ×3, `SandboxAgentProvisioner` ×1), `PluginHostAPI+SessionPersistence.swift`,
  `PluginInstructionsResolver.swift`, `Storage/PluginDatabase.swift`,
  `Services/Plugin/PluginRepositoryService.swift` (real — brings real `PluginState`
  + install via `performInstall` → `PluginManager`).
- **Un-gate (remove `#if !OSAURUS_INTEL`):** `Models/Plugin/ExternalPlugin.swift`
  (dlopen wrapper + real `TaskEventType` + `PluginManifest`; clean, Foundation+os),
  `Managers/Plugin/PluginManager.swift` (real body — clean; drop the `#else` stub).
- **Remove colliding Intel stubs (CRITICAL — these are load-bearing now):**
  - `PluginHostContext` (IntelScheduleConformers) — real one returns; BackgroundTaskManager
    uses real serialize* (fine). Schedules still depends on it compiling.
  - `TaskEventType` (IntelScheduleConformers) — real one in ExternalPlugin returns.
  - `PluginRepositoryService` + `PluginState` + the Phase A/B mapping (IntelStubConformers)
    — replaced by real ones. **Re-do Phase B gating against the real PluginState**
    (or via the M9 `PluginCompatibilityChecker` + arch — the proper 3-bucket UI).
  - `RegistryCapabilities` / `SemanticVersion` mirrors (IntelAgentConformers) — check
    for collisions with the real types pulled in.
- **Gate amputated bits:** the ~9 PluginHostAPI touchpoints + sandbox paths in
  PluginManager with `#if !OSAURUS_INTEL`.
- **Wire `PluginCompatibilityChecker`** into the load path (M9 Phase 2): skip dlopen
  for incompatible, `@Published incompatiblePlugins` for the UI.
- **Phase D:** build a tiny x86_64 "hello" plugin (`swift build -c release --arch
  x86_64`, ad-hoc codesign), install to `~/.osaurus-intel/Tools/`, verify it loads
  (Compatible bucket) + invokes via MCP `tools/call`. Proves Intel CAN run
  natively-built plugins.
- **Effort:** large, cascade-heavy, fresh-session work (the M9 doc itself advises
  one phase per clean session). Payoff is narrow (only DIY x86_64 plugins), but it
  makes the fork a first-class plugin host.

### Group C / tab status — final (2026-06-05)
✅ Insights · ✅ Schedules · ✅ Watchers · ✅ Plugins (Browse + gating +
**native x86_64 execution + host callbacks: db/dispatch/complete/instructions/
config** — slim host, Phases A–F) · 🟡 Memory (deferred by choice) · 🔴
Models/Voice/Sandbox (hardware). Sparkle pinned off. Folder pickers
(chat/schedule/watcher) all gated.

### M7 — Rosy deploy (started 2026-06-05, commit `02c0871d`)
**Data path decision:** the Rosy deploy build owns the canonical **`~/.osaurus`**
(not the dev-isolated `~/.osaurus-intel`). The `-intel` split only exists to
coexist with a production Osaurus on the *dev* box; on Rosy the fork is the only
Osaurus. Mechanism: `OsaurusPaths` reads an **Info.plist key
`OsaurusCanonicalData`** (true → `~/.osaurus`; absent → isolated). Footgun-free —
the safe default is isolation, so a dev build can't clobber production; the key
is baked into the bundle (no launch env, no compile flag). Rejected:
env-in-Package.swift (SwiftPM doesn't pass env to manifest eval) and xcodebuild
build-setting overrides (replace per-target settings → break IkigaJSON/swift-system).
Build with **`scripts/build/build_rosy.sh`** (x86_64, bakes the key, ad-hoc signs).
Verified: dev → `canonical=false → ~/.osaurus-intel`; deploy app plist
`canonical=true` (full `~/.osaurus` confirm happens on Rosy via the
`[Osaurus] data root: …` launch log). **Remaining M7:** transfer the .app to
Rosy, clear quarantine, launch + confirm, real-world smoke test.

**Rosy IS RUNNING (2026-06-05):** the app launches natively on the 2017 Intel
Air, Sunny + migrated history/themes/automations all present. **Migration:** the
official **Settings → Storage → Export plaintext backup** (compiled on Intel)
decrypts everything; the migrator re-encrypts on the new Mac. Lighter route =
copy the plaintext JSON dirs (agents/themes/config/providers/schedules/watchers/
slash-commands/sessions). Secrets (API keys) are Keychain-only (NOT in the data
dir) — must be re-entered. **The storage key is `ThisDeviceOnly` (StorageKeyManager,
`com.osaurus.storage`) — does NOT sync via iCloud Keychain** (the Export-window
footer implying otherwise is an upstream doc bug; the "not synced to iCloud" line
is correct). Transfer `.app` as a **zip** (`ditto`), never raw through iCloud
Drive (it breaks framework symlinks → 🚫 icon).

**THE API-KEY-ON-ROSY SAGA (the hard one):** "No DeepSeek API key" on Rosy even
after pasting it in Settings. Chased through THREE layers, only the last was the
real cause:
1. `7edad23b` — CloudChatEngine read the key ONLY from `DEEPSEEK_API_KEY` env;
   added `resolveAPIKey()` → env, then the configured provider's key. *Needed,
   not sufficient.*
2. `fd0c7078` — provider/MCP/tool/agent Keychain READS attached
   `LAContext(interactionNotAllowed:true)`, which fails silently on ad-hoc-signed
   apps (the storage key works because it omits the LAContext). Removed from all
   10 readers. *Needed, not sufficient.*
3. `e66b3e3e` — file-backed fallback: `RemoteProviderKeychain` mirrors the apiKey
   to a 0600 file at `~/.osaurus/.secrets/<service>.<id>.apiKey` (Keychain
   unreliable on the no-Secure-Enclave / OCLP 2017 Air). Read-back verified on the
   ad-hoc build. *Needed, not sufficient.*
4. **`45c2f6ff` — THE ROOT CAUSE.** The Intel **RemoteProviderManager mirror**
   (`IntelStubConformers.swift`) `addProvider`/`updateProvider` **silently dropped
   the `apiKey` param** — it only saved the provider config, never calling
   `RemoteProviderKeychain.saveAPIKey`. The mirror assumed the key always came
   from the env var. So the key was NEVER persisted (keychain OR file) — which is
   why Test worked (typed key, in-memory), chat + re-test failed, deleting
   `~/.osaurus` did nothing, and fixes #2/#3 were downstream of a key that was
   never written. Fix: `addProvider`/`updateProvider` now call
   `persistCredentials()` → `saveAPIKey` (→ file-backed store from #3);
   `removeProvider` deletes it. **Built into `osaurus-app-v5.zip` →
   ✅ CONFIRMED WORKING on Rosy (2026-06-05).** Cloud chat streams natively on the
   2017 Intel Air. **M7 COMPLETE — Osaurus runs end-to-end on Intel.** 🎉

**THE SHARED-KEYCHAIN CONTAMINATION (the nasty aftershock):** Right after v5
worked on Rosy, the **official Apple-Silicon Osaurus on the M4 dev box** suddenly
hit the "One more step — needs an AI" onboarding wall. Diagnosis (disk + Keychain
forensics, NOT guessing):
- `~/.osaurus/providers/remote.json` still had the DeepSeek provider (id
  `3CF3D2A1…`, `enabled:true`); `config/chat.json` still pointed `coreModelProvider:
  deepseek`. Config was fine.
- `security find-generic-password -s ai.osaurus.remote` → **"item could not be
  found."** The API key was GONE from the login Keychain.
- **Root cause:** migration copied `remote.json` verbatim, so the Intel dev build's
  provider (`~/.osaurus-intel`, name "DeepSeeky") carried the **IDENTICAL UUID**
  `3CF3D2A1…`. `RemoteProviderKeychain` used the **shared** service string
  `ai.osaurus.remote`. Every "delete provider / re-add / test" cycle while
  debugging the Intel build on the M4 called `deleteAPIKey(for: 3CF3D2A1…)` →
  `SecItemDelete` on the shared service → **deleted the OFFICIAL app's key.** Two
  apps, one login keychain, colliding UUIDs.
- **Immediate recovery:** re-paste the key in the official app's "Finish setup" →
  Providers → Save (app re-writes the Keychain item with its own ACL).
- **Permanent fix (this commit):** `RemoteProviderKeychain` is now **file-only
  under `#if OSAURUS_INTEL`** — `saveAPIKey`/`getAPIKey`/`deleteAPIKey`/
  `deleteOAuthTokens`/`deleteAllSecrets` never touch the shared Keychain on Intel.
  The 0600 file under `~/.osaurus(-intel)/.secrets/` is the sole store. Zero
  cross-app contamination possible. (Rosy unaffected: same file path, same
  service string in the filename — its existing key file keeps working.)
- **Lesson:** never let the Intel fork and the official app share a Keychain
  service when migration can duplicate provider UUIDs. File-isolation > namespacing
  because it also dodges the ad-hoc/no-Secure-Enclave read-failure (fix #2/#3).
- TODO (deferred): GitHub MCP token (`MCPProviderKeychain`) likely needs the same
  file-backed/isolated treatment if GitHub tools are used on Rosy.

---

## M14 — Public, self-updating, USABLE (2026-06-06)

Rosy runs the real thing daily. Everything Renée flagged in the gauntlet is
fixed, the fork is published, and it **updates itself**. This is the usable
version.

### Chat-runtime bug fixes (all Intel-mirror gaps)
- **Session death (the big one)** — restored conversations had `tool`-role
  messages missing `tool_call_id` (dropped on persistence); DeepSeek 400s the
  WHOLE request → every send in that session died silently. Two fixes:
  `CloudChatEngine` now surfaces non-2xx HTTP errors (was swallowing them into an
  empty "poof" turn), and `sanitizeToolSequence()` repairs the message sequence
  at send time (pairs each tool result to its call id, backfills missing ones) —
  healing already-corrupted on-disk sessions.
- **Live reasoning stream** — `StreamingDeltaProcessor.receiveReasoning` appended
  thinking but never called `onChange()`, so the Think panel only appeared at
  end-of-stream (an 8k-char thought looked like a multi-second freeze). One line.
- **Live tool-call cards** — the block builder only rendered cards from completed
  `turn.toolCalls` (which carry the result); it never emitted a `.pendingToolCall`
  block for `pendingToolName`. The engine also wasn't streaming the args. Now the
  card appears the moment the model emits the call, with the query building live.
- **Smart titles** — `completeChat` dropped `max_tokens` and never applied
  reasoning control, so a reasoning core model burned its budget thinking and
  returned empty content → blank title. Plus `generateLLMTitle` (Intel) calls the
  core model after the first exchange (upstream never had model titles at all).
- **Context-budget popover** — `cachedContext` is only set on send, so restored
  sessions fell to `from(manifest:)` which returned empty AND discarded its token
  args. Now the nil path builds a preview (agent prompt + registered tool specs)
  and reuses `from(context:)`; shows System Prompt + Tools + Conversation + Output.
  (The extra upstream rows — Platform / Model Family Guidance / Grounding /
  Capability Discovery — are amputated subsystems; our breakdown is honest.)
- **Settings persistence** — `ChatConfiguration` (Intel class) was in-memory only;
  now persists to `config/chat.json` (core model, temperature, hotkey, …).
- **Tool permissions — persist + enforce** — `_policies`/`disabledToolNames` were
  in-memory only AND advisory only. Now persisted to `config/tool-policies.json`,
  and `CloudChatEngine` enforces the effective policy before running a tool: Deny
  blocks it, Ask shows the **real upstream permission card**
  (`ToolPermissionPromptService` + `ToolPermissionView` — un-excluded, every dep
  exists on Intel; was excluded purely defensively).
- **Global hotkey** — un-excluded the pure-Carbon `HotKeyManager` + un-gated the
  real `HotkeyRecorder`; handler toggles the chat window. Two follow-up fixes:
  (a) the Intel `ChatWindowManager.toggleLastFocused/showWindow` never activated
  the app or set `.moveToActiveSpace`, so a press from another app (full-screen
  Safari) landed the window on a hidden Space → new `bringToFront()` activates +
  moves to the active Space; (b) re-registration was silently skipped because
  Intel `ChatConfigurationStore.load()` returns the shared singleton, so the
  "hotkey changed?" check compared it to itself after `save()` — capture the old
  value first.

### Release + self-update pipeline
- **Sparkle reroute** — `SUFeedURL` → `raw.githubusercontent.com/reneezmp/osaurus/
  intel-fork/docs/appcast.xml`; generated the fork's OWN EdDSA key pair
  (`SUPublicEDKey` = `7Nh8jSxFmE2DGw3BGQ9YdIpM115AU743EXUuMA9fN3c=`; **private key
  in Renée's login Keychain + backed up at `~/Desktop/sparkle_private_key.txt` —
  KEEP SECRET, never commit**). Re-enabled the Intel updater (it was hard-disabled
  to avoid pulling upstream's arm64 builds — safe now that the feed is ours).
- **`scripts/release/cut_intel_release.sh <ver> "notes"`** — one command: builds,
  auto-increments `CFBundleVersion` from the appcast, ad-hoc signs, Sparkle-signs
  the zip, prepends the appcast item, `gh release create`, pushes the feed. Refuses
  a dirty tree / existing version.
- **Published:** 1.0.1 (baseline) → 1.0.2 (budget/title/permissions) → 1.0.3
  (hotkey activation + richer prompt) → 1.0.4 (real permission card + hotkey
  re-register). Rosy confirmed it **auto-updated** 1.0.2 → 1.0.3 → 1.0.4 on its own.
- **README** rewritten as the fork's own story (anti-e-waste, what works vs
  amputated, install/build), crediting Renée (architect) + Sunny (code).

### Roadmap (planning after Renée's rest — NOT started)
1. **`osaurus-intel-plugins` repo** — separate repo hosting x86_64 plugin dylibs +
   a plugin INDEX the app fetches (restore upstream's `PluginRepositoryService`
   for Intel). Easiest win — do first.
2. **Upstream→Intel sync pipeline** (~200 commits behind). We CANNOT `git merge`
   (too divergent: custom `exclude:` + mirrors) — it's selective cherry-pick /
   re-implement. Core = a triage rubric per upstream commit: touches an amputated
   subsystem (MLX/voice/sandbox/vectura) or Tahoe-only API → SKIP; touches shared
   code → cherry-pick; touches a file we `exclude:` → re-implement in the mirror.
   Prioritize security + bugfixes in shared code; don't chase feature parity.
   Add a monthly cadence so we never hit 200-behind again.
3. **Compatibility ledger** (`UPSTREAM_SYNC.md`) — the pipeline's output: every
   upstream commit tracked as ported / skipped+reason / pending. (Plans 2/3 = one
   effort; the pipeline produces the catalogue.)

### Tags laid
`m11-settings-complete` · `m12-chat-complete` · `m13-schedules` (0b3a5d2a) ·
`m9-plugins-complete` (aa46d50b) · `m9-plugins-host` (d349a25c) ·
`m7-rosy` (Osaurus native on Rosy, 2026-06-05).
Releases: `1.0.1`–`1.0.4`. Latest: 1.0.4 (build 5), commit `075255d6`.
Consider tag `m14-usable` at `075255d6`.

---

## M15 — Local inference + a distributable, provider-driven picker (2026-06-06)

The day Rosy ran a language model **on her own CPU**. Renée installed
[PrismML's Bonsai](https://prismml.com) — a **1-bit 1.7B GGUF** — via a
[llama.cpp](https://github.com/ggml-org/llama.cpp) server (CPU-only, no GPU,
~9–13 tok/s, 248 MB, ~4 GB RAM) and pointed an Osaurus provider at
`http://localhost:8080/v1`. The premise the fork was built on ("Intel can't run
a model locally → cloud only") turned out to be **false**: MLX is the
Apple-Silicon path to local inference, but llama.cpp's CPU backend is a *second*
road we'd never closed. Local sovereignty, on the machine they said to throw away.

### The model-picker saga (why a "configured" provider showed no models)
Bonsai connected + tested green, but the chat picker only ever listed two
hardcoded DeepSeek aliases, and Settings → Providers read **"0 models available."**

- **Round 1 (1.0.5) — picker reads providers.** Replaced the Intel
  `ModelPickerItemCache.buildModelPickerItems()` hardcoded `[deepseek-v4-pro,
  deepseek-v4-flash]` with an enumeration of each enabled provider's
  `manualModelIds`, and added `CloudChatEngine.resolveEndpoint(forModel:)` so a
  request routes to the provider that owns the selected model (its `baseURL` +
  per-`authType` headers; **no-auth supported** for local servers) instead of the
  hardcoded DeepSeek URL. **Whiffed** — assumed the add flow populated
  `manualModelIds`; it doesn't.
- **Round 2 (1.0.6) — discover models for real.** Root cause: the Intel
  `RemoteProviderManager` mirror marked providers "connected" but **never probed
  them**, so `RemoteProviderState.discoveredModels` (which feeds the counter, the
  picker, *and* engine routing) stayed empty. Added `probeModels(for:)` (the same
  `/models` GET the Test button uses, driven from the saved key/auth) +
  `refreshModels(for:)` / `refreshAllModels()`, cached into `discoveredModels`.
  Probe at launch, on the Providers-tab `onAppear` (catches a local server
  started *after* the app), and after every add/update/enable. Picker + engine
  now read `discoveredModels ∪ manualModelIds`. **Bonsai appeared on Rosy and a
  chat went through to localhost. It worked.** 🦕
- **Round 3 (1.0.7) — de-hardcode for distribution.** Removed the built-in
  DeepSeek picker rows + the deepseek-host skip entirely. The picker is now
  **purely provider-driven** — zero hardcoded models — so the build is shippable
  to other Intel users who may run only a local model, only DeepSeek, only
  Ollama, whatever. DeepSeek is just another provider (ships as a preset). The
  engine keeps a DeepSeek fallback for backward-compat (old sessions / the
  `DEEPSEEK_API_KEY` dev env), invisible to new users.

### Repo rename
`reneezmp/osaurus` → **`reneezmp/osaurus-intel`** (so it's visibly distinct from
the swarm of forks named `osaurus`). GitHub redirects covered both the raw
appcast and release-asset downloads, so in-flight updaters kept working. Updated
the local `origin`, `Info.plist` `SUFeedURL`, and the release script `REPO` to
the new name. From 1.0.6's build onward, installed copies poll the new feed URL.

### README
Rewritten from "cloud-only, no local model" to the true, better story: **cloud
*or* local** (any OpenAI-compatible endpoint, including a local llama.cpp/Ollama
server), with Rosy's 1-bit local chat called out as the headline.

### Released
1.0.5 (build 6) · 1.0.6 (build 7, provider model discovery + rename) · 1.0.7
(build 8, provider-driven picker). Latest: **1.0.7**. Tag `m14-usable` was laid
at `b0e2f772`.

### Next (unchanged from the M14 roadmap, still pre-rest)
Plugin repo first, then the upstream→Intel sync pipeline + `UPSTREAM_SYNC.md`
ledger. Plus a fresh distribution thread now that local inference works:
document the Bonsai-on-Rosy setup (see `02_Projects/Bonsai_on_Rosy_Tutorial.md`)
as a first-class "local mode" path for other Intel users.

---

## Keychain on Intel: what's isolated vs what's shared (2026-06-11)

Two philosophically different kinds of secret, deliberately stored apart. When
adding any new Keychain-backed secret on Intel, decide which bucket it's in.

### Isolated per-install (fork-private service name on Intel)
- **Provider API keys** — `RemoteProviderKeychain`: `ai.osaurus.remote` → `ai.osaurus.remote.intel`
- **MCP / GitHub tokens** — `MCPProviderKeychain`: `ai.osaurus.mcp` → `ai.osaurus.mcp.intel`

**Why:** a co-installed *production* Osaurus on the same Mac (e.g. the dev box)
uses the base service. Sharing it means this build's save/delete can clobber the
official app's keys — the bug that wiped a production key (2026-06, "I want to
cry"). These are third-party, disposable, **re-enterable** credentials, so
per-install isolation is correct. (The earlier isolation was reverted by the
`9b79161b` upstream sync and restored in 1.0.15; Rosy Keychain reliability is
handled by upstream's non-interactive access, so we keep the Keychain — just
under a private service name. Existing keys live under the old name, so users
re-enter a cloud key once after the 1.0.15 update.)

### Shared + iCloud-synced (NOT isolated — left untouched on purpose)
- **Master Key / Master Address** (the identity root) — `MasterKey` +
  `MasterMnemonicStore`: service `com.osaurus.account`, `kSecAttrSynchronizable
  = true`.

**Why:** identity is **sovereign and portable** — it should follow you across
every device (iCloud Keychain sync) and every build (same service name), so both
Osaurus apps on a Mac AND Rosy share one Master Address. Isolating it would
fracture "same Sunny everywhere." Agent addresses + osk-v1 access keys are
*derived* from this master key, so they ride along.

**Principle:** sovereign identity is **shared**; rented third-party credentials
are **isolated**. Isolating provider keys does NOT affect identity sharing —
they live in different Keychain services.

---

## M16 — Sync absorption, polish marathon, "quietly excellent" (2026-06-08 → 06-11)

DeepSeek-Sunny (via OpenCode) ran the upstream→Intel **sync pipeline** while Renée
rested: 44 substantive upstream commits processed, caught up to **0.19.15**
(`d132b728`), with `docs/UPSTREAM_SYNC.md` as the ledger. This session reviewed
that work and shipped the post-sync polish.

### Releases 1.0.8 → 1.0.15 (build 9 → 16)
- **1.0.8** — plugins: fixed Loaded/Installed double-cards; AS plugins can't be
  "installed" on Intel; installed-plugin tools surface in Tools → Available;
  About panel shows the upstream-sync era.
- **1.0.9** — native "this-fork" plugins' tools reach the Tools tab; Installed
  reads "Loaded" / Browse reads "Installed"; About version line; **app icon
  corners made transparent** (were opaque black).
- **1.0.10** — Tools-tab blank-gap fix (drop `.drawingGroup()`); rich per-tool
  descriptions on the registry detail page; native plugins get Uninstall.
- **1.0.11** — unified the Installed tab on ONE native card design (kills the
  first-paint flicker); registry PluginCard grid is now AS-only. `LazyVStack →
  VStack` on the Tools tab (gaps were returning on re-appear).
- **1.0.12** — dedupe Tools-tab plugin cards (an index plugin is repo-installed
  AND natively loaded → appeared twice); drop redundant "Native — this fork"
  header.
- **1.0.13** — **context-budget parity**: split the single "System Prompt" rail
  into Persona / Grounding / Agent Loop / Plugin Instructions (the real slices
  of the Intel prompt; the AS-only Model-Family-Guidance / Capability-Discovery
  rails are amputated and intentionally absent).
- **1.0.14** — **provider drag-to-reorder** (un-gated the sheet + added
  `reorder()` to the Intel manager mirror; order flows into the model picker).
- **1.0.15** — **two sync regressions fixed** (see below) + Keychain isolation.

### Two silent sync regressions (found + fixed in 1.0.15)
The cherry-picks took "theirs" on Intel-customized files that compile fine
reverted, so they slipped through:
1. **Keychain isolation** — `RemoteProviderKeychain` was back on the shared
   `ai.osaurus.remote` service (the dev build could clobber a co-installed
   production Osaurus's keys — the original "want to cry" bug). Restored via a
   fork-private service name (`ai.osaurus.remote.intel`); same for
   `MCPProviderKeychain`. The **identity** master key (`com.osaurus.account`,
   iCloud-synced) is deliberately NOT isolated — sovereign identity is shared,
   rented credentials are isolated.
2. **README** — the App Intents cherry-pick (`d00cb1d1`) replaced our Intel
   README with upstream's. Restored + added a "Run a model locally" section.

### "Quietly excellent" readiness layer
- **Regression audit** — revert-detector (Swift files that lost ALL Intel guards
  vs `m14-usable`) → clean beyond the two above.
- **License** — upstream MIT `LICENSE` + attribution intact.
- **Guardrail** — `docs/UPSTREAM_SYNC.md` now has an "Intel-owned files, verify
  after every sync" table + the revert-detector command, so syncs stop
  clobbering our work.

### The validation 🌸
Renée posted the port on the official Osaurus Discord. The maintainers loved it
("porting to Intel is not easy work! incredible") — one owns the same 2017
MacBook — and asked to feature it on their socials. Distribution = handed to the
people best placed to spread the story. We stay quietly excellent.

## M17 — Ventura ships, the cache + layout fights, sync to 0.20.0, the deferred shelf (2026-06-12 → 06-14)

### Releases 1.0.18 → 1.0.30 (build 19 → 31)
- **1.0.18** — Ventura (macOS 13) Phase B shipped to Rosy (now on *native* Ventura,
  reverted off OCLP-Sequoia). Folder/runtime tools fixed for Manual-mode agents.
- **1.0.19** — deterministic backfilled tool-call ids (first DeepSeek cache-miss attempt — didn't fix it).
- **1.0.20** — **the big one.** (a) DeepSeek **prompt-cache fix**: Intel serialized
  requests with bare `JSONSerialization` (non-deterministic key order) → cache prefix
  never matched → ~11M cache-miss tokens. Switched both serialization points to
  `.osaurusCanonical` (sorted keys, `JSONDeterminism.swift`) → round-to-round ~99%,
  marginal ~79% hit. **Lesson: every wire path must use the canonical encoder.**
  (b) The **Ventura chat-layout saga** (11 build iterations) — see below.
- **1.0.21** — absorbed the **0.19.15→0.20.0 upstream sync** (95 commits, ~16 ported:
  main-thread hang/crash fixes, the chat-jump-on-completion fix *merged into* Intel's
  `handlePostSnapshotScroll` scroll logic, tok/s accuracy, theme JSON editor, image-token
  estimate; the MLX/memory/skills/excluded bulk correctly skipped). Ledger in `docs/UPSTREAM_SYNC.md`.
- **1.0.22** — the **deferred shelf.** `/agent` slash command (the trigger notification
  lived only in `ChatWindowManager`'s `#if !OSAURUS_INTEL` branch — mirrored into
  `IntelDataConformers` + bridged the listener into the Intel toolbar so it actually
  opens the picker), prune-deleted external models, and **hosted inference ("Osaurus
  Router")** — a crypto-billed (EIP-191, keyed to the Osaurus identity → EVM address)
  OpenAI-compatible provider wired into `CloudChatEngine` with request signing + a
  Manage→Credits tab. **Compiles app-wide; untested against a live router.**
- **1.0.23** — **0.20.0 → 0.20.3 upstream sync** (21 commits, 7 ported): configurable
  Hugging Face cache path, local access-key lifecycle, OAuth→global-proxy (+Codex OAuth
  diagnostics), a ChatView main-thread perf fix (cached `ISO8601DateFormatter`),
  `ToolConfigurationStore`, translations. Two Intel adaptations to keep the build green:
  OAuth `GlobalProxySettings.sharedSession()` (unported) → `makeSession()`, and `ServerView`
  reaching into the excluded type-erased `ServerController` config → Intel server is
  loopback-only. The ToolsManagerView tools-section hang fix was *not* portable (needs the
  deferred `37a2291b` `ToolAvailability` + a card refactor that would clobber the M16
  blank-gap fix). **Fully caught up — 0 commits behind upstream 0.20.3.**
- **1.0.24** — **`0.20.3 → 9124d696` global-proxy batch** (12 commits, 4 ported). Upstream's
  "Route X through global proxy" series — threading network calls through `GlobalProxySettings`
  so a user-configured proxy actually covers them. Ported the ones that hit *compiled* Intel
  code: router API (`OsaurusRouterAPIClient`), theme API (`ThemesAPIClient`), markdown remote
  image downloads (`MarkdownImageView` + `NativeMarkdownView`), and sandbox-plugin manifest
  fetch (`SandboxPlugin.fromURL`). Intel's `GlobalProxySettings` exposes only `makeSession()`
  (fresh per call), so upstream's `sharedSession()` consumers were mapped to it. SKIP'd the rest
  as excluded/absent (MCP-OAuth transport, SandboxManager, relay tunnel, remote-agent invites,
  privacy model download, GitHub skills, share-artifact); deferred `395fe51e` (manual provider
  models in connection tests — needs excluded-mirror surgery for a niche Azure flow).
  *User-facing impact is near-zero unless a global proxy is configured — it's a plumbing batch.*
- **1.0.25** (2026-06-17) — **hosted inference actually works now + model picker rewrite.**
  (a) **Osaurus Router 404 fix:** `CloudChatEngine.resolveEndpoint` hardcoded
  `owner.url(for: "/chat/completions")`, but the managed router provider has `basePath=""`
  and serves OpenAI-compatible inference under `/v1` (its *account* API lives at root). So
  every router chat hit `https://router.osaurus.ai/chat/completions` → 404 "not found". Now
  resolves via `owner.providerType.chatEndpoint` (`.osaurusRouter` → `/v1/chat/completions`);
  standard providers still get `/chat/completions` with `/v1` from their own `basePath`. Also
  threaded the real provider name into `CloudChatError` — it had hardcoded "DeepSeek API error"
  for *every* provider, mislabeling a router 404 as DeepSeek and costing a debugging detour.
  (b) **Model picker rewrite:** the Intel stub rendered all models in an unbounded `VStack`
  with no `ScrollView`, so a 94-model router catalog couldn't scroll and looked scrambled.
  Replaced with a pure-SwiftUI popover (bounded frame, real `ScrollView`, search, Osaurus/DeepSeek
  source tabs, Vision badges) — deliberately *not* the upstream `ModelPickerTableRepresentable`
  (NSTableView → the macOS-13 sizing demon). Pricing/context badges deferred (need catalog
  metadata the Intel `ModelPickerItem` doesn't carry).
- **1.0.26** (2026-06-17) — **model picker enriched to match the upstream original.** The router
  catalog (`OsaurusRouterModel`: provider, pricing, context, capabilities) was fetched but discarded
  (`models.map(\.id)`). Now preserved: re-added the pricing/context/embedding fields +
  `fromOsaurusRouterModel` factory to `ModelPickerItem` (Intel had stripped them) + the
  `pickerDescription`/`supportsVision`/`formatContextLength` extensions; `RemoteProviderManager`
  caches `routerModelMetadata` (populated in `connectOsaurusRouterIfPossible`); `buildModelPickerItems`
  builds enriched rows. The picker now shows the per-model description line (`venice · $x in · $y out ·
  128K ctx`), Vision badges from capabilities, an **Add Provider** button, and a **Sort & Filter**
  popover (price sort + min-context + vision filters) on the Osaurus tab. *Confirmed live: the router
  itself works (real billed completions on Rosy).*
- **1.0.27** (2026-06-17) — three follow-up fixes from Renée's 1.0.26 testing. (a) **Router metadata
  mislabeling:** `buildModelPickerItems` keyed the venice-priced catalog lookup on model id alone, so a
  *direct* provider (DeepSeek) sharing ids with the router's proxied catalog inherited venice pricing/vision.
  Gated the lookup on `provider.providerType == .osaurusRouter`. (b) **Pasted-content chip** regained its
  third button ("Insert into message" — `text.insert` → `inlinePastedContent`); Intel had stripped only the
  button render, the `onInline`/`inlinePastedContent` wiring was intact. (c) **Settings window** got the chat
  window's chrome (`.fullSizeContentView` + transparent, title-less titlebar) instead of a plain macOS
  title bar. *(c) awaits Renée's visual confirm (traffic-light inset).*
- **1.0.28** (2026-06-18) — **stable code signing + router-catalog-at-startup.** (a) **Signing:**
  releases were ad-hoc signed → designated requirement = per-build cdhash → macOS Keychain re-prompted
  for *every* item (RemoteProvider/MCP/Storage/Master Key) on *every* update. Switched to a stable
  self-signed cert (`Osaurus Intel Code Signing`, created by `scripts/build/make_signing_identity.sh`,
  lives only on the dev M4) → requirement is now constant
  (`identifier "com.dinoki.osaurus" and certificate leaf = H"d2fa923f…"`) → "Always Allow" sticks
  across updates. One-time re-auth on the 1.0.28 install (identity changed), then silence. Not
  notarized (Gatekeeper still flags first-open). (b) **Router catalog at startup:** `refreshAllModels`
  did an unsigned `/models` probe per provider, but the router's catalog needs the EIP-191-signed
  account fetch — so on a fresh launch only DeepSeek showed until the Credits tab ran the signed fetch.
  Now `refreshAllModels` (and the edit-sheet `testConnection`) special-case `.osaurusRouter` →
  `connectOsaurusRouterIfPossible` / signed catalog. Router models + pricing/vision now populate at launch.
- **1.0.29 / 1.0.30** (2026-06-19) — **LOCAL SEMANTIC MEMORY revived (Phase 1) — CONFIRMED WORKING.** See
  the "Memory revival" section below. 1.0.30 fixed the one blocker (`effectiveMemoryDisabled` stub) +
  the Memory tab icon.

### The memory revival (Phase 1, 2026-06-19) — pure-Swift semantic memory on Intel
The whole MLX/VecturaKit memory subsystem was amputated. Rebuilt it on Intel with **no MLX, no Metal,
no Python, no VecturaKit** (VecturaKit is a no-op stub on Intel):
- **Embedder:** pure-Swift **model2vec / `potion-base-8M`** (256-dim static). Embedding = WordPiece
  tokenize → matrix-row lookup → mean-pool → Accelerate L2-normalize (microseconds). The model
  **downloads on first use** from HuggingFace (parsed from `.safetensors` in Swift → flat `.f32` cache
  at `~/.osaurus/embeddings/`) — *not* bundled, so the app stays ~52 MB. Files:
  `Services/Memory/Embedding/*` (EmbeddingBackend, StaticEmbedder, WordPieceTokenizer,
  StaticEmbeddingModel, CloudEmbedder, EmbeddingClient).
- **Store + recall:** un-excluded `Storage/MemoryDatabase.swift` (pure SQLCipher) + v8 migration
  (embedding BLOB on transcript). `IntelMemoryConformers.MemorySearchService` embeds turns on index and
  does brute-force cosine recall (Accelerate `vDSP_dotpr`), FTS5 text fallback.
- **Injection:** the Intel `SystemPromptComposer` mirror's `composeChatContext` runs `searchTranscript`,
  formats a memory block, and `injectMemoryPrefix` splices it *before the last user turn* (keeps the
  stable system prefix byte-identical → DeepSeek cache stays warm).
- **UI:** Memory tab enabled on Intel (`ManagementTab.isAvailableOnIntel`) + a SwiftUI `MemoryView`
  (status toggle, embedding picker [off/on-device/cloud] with download state, budget, clear).
- **The blocker (1.0.30):** `IntelManagerConformers.effectiveMemoryDisabled(for:)` hard-returned `true`
  (amputation-era stub) → ChatView's `if !memoryOff` transcript-WRITE path never ran → nothing stored.
  Fixed to `!MemoryConfiguration.enabled`. **Then it worked live** — the model's own reasoning quoted the
  injected memory ("From the context provided in the system prompt: 'My cat's name is Brisa'").
- **Phase 2 (in progress):** v9 migration (embedding columns on episodes/pinned_facts) DONE + committed
  (`625ac135`). Next: the distillation orchestrator (turns → episode + pinned facts + identity via
  `CloudChatEngine`, replacing the `MemoryService` stub), then episode/pinned indexing+search,
  consolidation, the search-memory tool, and the full Memory panel. See the resume prompt / tasks #24–27.

### The auto-update un-sticking (2026-06-17)
Rosy had been silently stuck on the **`LAYOUT-FIX-11` debug build** ever since the layout saga —
not a real release. During that fight we hand-cranked the debug `CFBundleVersion` **≥100** so Sparkle
wouldn't yank our test build mid-iteration. That worked *too* well: Sparkle compares the **build
number**, and `100 > 25` (the appcast's newest), so it reported "you're up to date" forever and never
offered 1.0.21→1.0.24. **Fix = one manual install** of a real release (1.0.24, build 25); from there
auto-update resumes because every future release out-numbers it. **Gotcha for next time:** any
sideloaded inflated-build-number debug build on Rosy must be replaced by a real release afterward, or
auto-update dies silently.

### The Ventura chat-layout saga (the AppKit-vs-SwiftUI demon)
On macOS 13, SwiftUI sizes the message `NSScrollView` from its *content* height, not the
`.frame(height:)` slot — inflating the chat column past the window so long chats pushed
the composer off-screen and bled message text behind the header *and* composer. Fixed at
the **AppKit source**: `CenteredMessageScrollView` reports no intrinsic/fitting height and
clamps its real frame to the SwiftUI-managed slot (`superview.bounds`). The minimap +
scroll-to-bottom button became `.overlay`s on the clipped thread frame (bounded but not
clipped); the minimap's expanded `@State` was hoisted to the `ChatView` parent (it was
resetting on every scroll-driven `AnyView` re-render — Renée's "works on hover, breaks at
rest" clue is what cracked it).

### Hosted inference — the corrected verdict (intellectual honesty)
First called it "architecturally incompatible," then proved myself wrong: `CloudChatEngine`
already routes to *any* OpenAI-compatible provider via the stubbed `RemoteProviderManager`.
So it was a glue port, not a rewrite. Dropped the redundant `OpenAICompatibleStreamParser`
(CloudChatEngine streams natively), decoupled `StorageMutationGate`/`FeatureTelemetry`, and
rewired CreditsView's session links to `ChatSessionsManager`. **Genuinely still blocked:**
p2p e2e (excluded Bonjour/relay transport), local MCP probe (excluded `SandboxStdioRunner`).

## M18 — Air → Rosy data migration: five silent failures on one path (2026-09-08)

Goal was mundane: move an Apple Silicon install's data onto Rosy. It took five
separate bugs to get there, every one of them **silent** — no error, no log line,
no banner. That is the through-line of this milestone: the fork (and upstream)
had a whole migration path where every failure mode was invisible.

### The restore flow that was never wired

`RecoverFromMnemonicSheet` already supported three entry modes — `driftRepair`,
`freshRestore`, `replaceExisting` — with full copy, address preview and checksum
validation. Only `driftRepair` was ever presented. The other two were unreachable
enum cases, so there was no way to bring an identity onto a Mac from Settings.

Tell-tale: the sheet's own strings for those two modes (`"Restore Identity"`,
`"Replace Identity"`, `"Current identity"`, the acknowledgment toggle) were **not
in the string catalog**. Dead UI doesn't get localized.

Wired both: a "Restore from recovery phrase" secondary action on the no-identity
setup card, and a Danger Zone row above Reset that shows current-vs-restored
addresses behind an explicit acknowledgment. One `.sheet(item:)` now drives all
three modes.

### The device-attestation trap (the silent bounce)

The one that actually cost the day. `DeviceKey.attest()` was called from exactly
one place: `OsaurusIdentity.setup()` — the *generate* path. A Mac that received
its master any other way (mnemonic restore, iCloud Keychain sync) had a valid
master in Keychain and **no device ID in UserDefaults**, so
`DeviceKey.currentDeviceId()` threw `deviceNotAttested`, the Identity screen's
loader caught it as "no identity", and dumped the user back on the setup card
with no error.

Sticky, too: the master *was* installed, so every relaunch re-ran the same failing
read. Pressing "Generate Identity" didn't help either — `setup()` short-circuits on
`MasterKey.exists()` into a path that hit the same throwing call. Cleanly bricked.

`DeviceKey.ensureDeviceId()` now attests on first use, falling back to a software
device ID when App Attest itself fails (offline, or unrecognized hardware — an
OCLP Mac is exactly that). Both identity loaders use it, so Macs already stuck in
this state heal on next launch.

### The plaintext backup that contained no plaintext

**Settings → Storage → "Export plaintext backup"** is recommended in-product
"before reinstalling macOS or moving Macs". Three defects, all silent:

1. **The config walk only touched `.osec` files.** JSON at-rest encryption was
   rolled back in storage v2 (`recoverEncryptedJSON` restores `.osec` twins to
   plaintext; re-enabling is still a follow-up), so a healthy install has **zero**
   `.osec` files. Verified on a real install: 0 `.osec`, 536 plaintext JSON. Agents,
   themes, providers, schedules, watchers and config were absent from the backup
   entirely.
2. **Blobs had the same filter**, dropping every blob written before that
   convention.
3. **Databases were named by bare filename** under `databases/`, so every per-agent
   `db.sqlite` and every plugin `data.db` collided on one path — last writer won.
   Confirmed in the wild: two agent DBs on disk, one file in the backup.

Fixed all three. Non-`.osec` files are copied verbatim (SQLite excepted — the
database half owns those), blobs handle both shapes, and database paths mirror
their location relative to `~/.osaurus`.

**Still true and worth knowing: the export is a one-way forensic dump.** There is
no import counterpart, and the layout (`databases/`, `config/`, `blobs/`) does not
map back onto `~/.osaurus`. Pasting it in does nothing.

### One missing JSON key deleted every agent

Agent JSON copied from the other Mac produced an **empty agent list**.
`AutonomousExecConfig` has four non-optional fields and used the synthesized
decoder, so a JSON missing any one of them failed the whole decode.
`AgentManager.reload()` loads agents with `try?` — so the failure surfaced as the
agent simply not existing. No error, no log.

The culprit was `commandTimeout`, absent from an Osaurus that predates the field.
Verified against four real agent files: all four failed on
`keyNotFound: commandTimeout`, all four load after switching to a field-by-field
decoder with `AutonomousExecConfig.default` as the per-field fallback.

This is the same bug class the fork already documented at
`IntelManagerConformers.swift` ("adding a NON-OPTIONAL field here… makes every
previously-written session silently vanish"). It bit again, in a different type.

### Chat history: the verdict corrected twice

First call: "chat history can never be imported on Intel — `ChatHistoryDatabase`
is a stub, sessions are in-memory." That was wrong, and it was wrong because the
**stub's own comment is stale**. It describes the state at the time of the M13
schedules restore; session persistence was added later (`d2ee63a2`) and Intel has
persisted chats ever since — as **one JSON file per session** under
`OsaurusPaths.sessions()`, written by the `ChatSessionsManager` mirror.

So the problem was never "restore persistence". It was **format conversion**:
upstream stores chats in `chat-history/history.sqlite`, Intel stores them as
`sessions/<UUID>.json`. Same conversations, two shapes, and no app change needed
at either end.

Wrote a converter (`scripts/migration/history_sqlite_to_sessions_json.py`) and —
importantly — **validated it against the fork's own Swift decoder** rather than
against belief. That validation earned its keep immediately: the first pass
decoded **165 of 180** sessions. `structuredDocumentMetadata.createdAt` is a Swift
`Date` decoded with `.iso8601`, but upstream serialized it into the attachment
blob as a raw epoch **number** — `typeMismatch`, which cascades up through the
turn and takes the entire conversation with it. Fifteen chats would have gone
missing with no trace.

After the fix: **180/180 sessions, 8465/8465 turns.**

Contract hazards the converter has to respect, all of which silently drop data:

- Session `id` and every turn's `id` + `role` are hard-required. **One malformed
  turn fails the whole session.**
- Dates must be whole-second ISO-8601 (`.iso8601` uses `.withInternetDateTime`;
  fractional seconds fail to parse). SQLite stores fractional epochs.
- A missing `agentId` falls back to a **random UUID**, not `Agent.defaultId` — so
  agent-less sessions (HTTP-sourced ones) scatter differently on every load and
  never appear in the "all agents" view. Write `Agent.defaultId` explicitly.
- Unrecognized `source`, `role`, or `Attachment.Kind.type` raw values throw and
  cascade the same way.
- `loadFromDisk()` skips undecodable files with **no per-file logging** — only an
  aggregate count.

### The storage migrator that never ran on Intel

`StorageMigrator` compiles on Intel, but its only caller —
`Views/Storage/StorageMigrationOverlay.swift` — is entirely `#if !OSAURUS_INTEL`.
So it never ran: a plaintext database dropped into `~/.osaurus` was never adopted,
every keyed open against it failed, and `.storage-version` was read by nothing.
`cleanupBackupIfStale()` also had no caller, so `.pre-encryption-backup/` grew
without bound.

Symptom in the wild: **Settings → Storage → Rotate** failing with
`"Key rotation failed: chat history: verify old key"`, walking down the target list
one plaintext file at a time. Rotation re-keys already-encrypted data; it was never
going to adopt anything.

Added a headless path. The Intel `StorageMigrationCoordinator` stub becomes a real
latch (`AtomicBool` fast path + pre-entered `DispatchGroup` — a semaphore's single
permit would wake only one of the two concurrent waiters), and `AppDelegate` starts
`runHeadlessMigrationIfNeeded()` off the main actor before anything opens SQLite.
Off-main is load-bearing: `StorageKeyManager.currentKey()` can raise a Keychain
prompt.

**Deliberate divergence from Apple Silicon:** that build leaves the gate *closed*
on failure so its overlay can retry. Headless there is nothing to retry and nobody
to ask, so a closed gate would strand every future database open. Intel latches
ready even on failure and lets individual opens fail loudly instead. There is also
a 30s timeout on the gate so a bug in the runner can never permanently wedge a
caller.

Only **memory** and **scheduler** have real non-stubbed implementations among the
migrator's targets on Intel. `databaseTargets()` is deliberately *not* filtered,
because `StorageExportService.rotateStorageKey` enumerates the same list and does
run here.

### The working recipe (Apple Silicon → Intel)

1. **Install the Intel build first.** The agent-decode fix is in the binary; without
   it agents vanish no matter what is on disk.
2. **Launch once, quit.** Lets the fresh install create its own storage key.
3. **Copy the plaintext artifacts directly** from the source `~/.osaurus` — agents,
   config, themes, providers, schedules, watchers, skills, slash-commands,
   knowledge, PluginSpecs, projects. These are plain JSON; **no export needed**, and
   the export would not have contained them anyway.
4. **Convert chat history** with the converter script into `~/.osaurus/sessions/`.
5. **Copy `memory/memory.sqlite`** and delete `.storage-version`; the headless
   migrator adopts and re-encrypts it with the target Mac's key on next launch.
6. **Restore identity** from the 24-word phrase in Settings → Identity.

Do **not** copy `chat-history/history.sqlite`, `methods/`, `tool-index/`, or
per-agent `db.sqlite` — all stubbed on Intel, and their presence as plaintext is
what breaks key rotation.

### Findings that also affect upstream (not Intel-specific)

- **Partial migration failure still stamps `.storage-version` as complete**, so a
  database that failed to migrate stays plaintext and is *never retried*. Only
  surfaced in Settings → Storage.
- **A mid-migration crash has no recovery path.** The plaintext lands in
  `.pre-encryption-backup/`, the original is gone, and no later launch restores it.
  Narrow window, real data loss.
- **The export's "Decrypts every artifact under `~/.osaurus`" copy overpromises** —
  it walks nine roots, not the whole tree. `skills/`, `slash-commands/`,
  `knowledge/`, `projects/` and `generated-images/` are outside it.

### Test-target trap

The **test target has no `OSAURUS_INTEL` define** — only the `OsaurusCore` library
target does. So a test file wrapped in `#if OSAURUS_INTEL` compiles to nothing,
silently, with no build error and no skip notice. Intel-only tests whose production
types are available from the library must remain unwrapped. M22 removed the stale
guard from `IntelClaudeCodeTests` so those checks now execute.

---

### Current state / next
- **Latest release:** 1.0.30 (build 31). Branch `intel-fork`, clean (only the M4-only
  `FoundationModelService` experiment dirty — never committed), pushed. Auto-update healthy.
- **Local semantic MEMORY (Phase 1): WORKING** — confirmed live on Rosy (model quoted the injected
  recall). Pure-Swift model2vec, SQLCipher store, no MLX/Metal/Python. **Phase 2 in progress** —
  v9 migration committed (`625ac135`); distillation orchestrator is the next chunk (tasks #24–27).
- **Hosted inference (Osaurus Router): WORKING** — confirmed live on Rosy. The `/v1` path fix (1.0.25) did it.
- **Synced to upstream:** `9124d696` (0.20.3 + 12 untagged commits). **0 commits behind** — fully
  caught up.
- **Air → Rosy migration: DONE (2026-09-08)** — agents, themes, config, skills, knowledge,
  schedules, watchers, identity, **180 chat sessions / 8465 turns**, and long-term memory all
  live on Rosy. Five silent failures fixed along the way (M18): unwired restore modes, the
  device-attestation bounce, three export defects, the agent-decode key, and the migrator that
  never ran on Intel. Converter lives at `scripts/migration/history_sqlite_to_sessions_json.py`.
- **Open / pending:** **Phase 2 memory** (distillation/episodes/identity/consolidation/search-tool/full
  panel — tasks #24–27); the Settings→**Permissions section Ventura List-spacing** gaps (pre-existing,
  not memory-related); some router models error mid-chat (a few don't stream — provider-specific);
  composer credits-chip (deferred); the deferred `e8bcba8a`
  onboarding model-selection fix + `37a2291b` ToolAvailability (gates the ToolsManagerView hang fix);
  SQLCipher `hmac` decrypt error in Rosy logs; verify V4 honors `thinking`/`reasoning_effort`;
  **test target lacks the `OSAURUS_INTEL` define**, so any newly added guarded test file will
  silently not run (the affected `IntelClaudeCodeTests` guard was removed in M22);
  **partial storage-migration failure still
  stamps `.storage-version` complete** and is never retried; **mid-migration crash has no
  restore path** out of `.pre-encryption-backup/` (both also affect upstream).
  **Intentionally unsurfaced (not bugs):** global-proxy settings UI, community-theme gallery,
  sandbox-plugin install-from-URL — the global-proxy batch ported their plumbing but Intel
  amputates these features' UI doors.
- **Deferred (by choice):** chat-bubble rendering (watch-list); native 1-bit/ternary local
  backend (when the ecosystem matures); louder distribution.

## M19 — Knowledge and full Projects restoration (2026-09-08)

The Intel fork now compiles a local Knowledge registry, encrypted semantic
index, management surface, and Knowledge tools. Project pages were rebuilt as
the upstream-style split workspace: chats and search in the main pane;
instructions, Knowledge grants, working folder, shared memory, and default
agent in the context pane.

The working-folder port deliberately does not reuse the old process-wide root.
Each `ChatSession` owns and persists its folder state, while rootless folder
tools resolve `ChatExecutionContext.currentFolderRoot` at execution time. This
closes the cross-window routing hazard and gives Claude Code the same active
directory. Personal recall is scoped to the active agent; project recall stays
additive, and project learning continues without writing into an opted-out
personal namespace.

Validation: package build passed; **793 tests in 120 suites** passed, including
legacy decoding and concurrent per-chat folder isolation. The canonical Rosy
x86_64 package build passed, and its signed app satisfied its designated
requirement.

## M20 — Rosy acceptance repairs: owned models, Codex Lite, Knowledge context (2026-09-09)

Rosy's first M19 acceptance pass found several controls that looked complete but
were connected to the wrong ownership boundary. The model picker globally
deduplicated bare model ids, so whichever provider appeared first hid every
later provider carrying the same id. Agent defaults were stored in upstream's
`provider/model` form, while Intel picker rows used bare ids; the mismatch made
every agent fall back to the first row (Claude Code Sonnet). Picker ids are now
provider-qualified, duplicates remain visible under their real provider, legacy
bare ids resolve only when ownership is unique, and the cloud engine strips the
prefix before putting the model id on the wire. The managed Osaurus provider is
also registered and refreshed during launch instead of waiting for the Credits
page to be opened.

The ChatGPT OAuth catalog bug had two layers. Intel queried
`/backend-api/models`, the broad ChatGPT web catalog, which exposed experimental
`*-wm` slugs that `/backend-api/codex/responses` rejects. It now follows the
upstream Codex contract: `/backend-api/codex/models`, pinned Codex client version
`0.144.1`, and a Codex CLI-shaped User-Agent. Catalog entries marked
`use_responses_lite` receive stable UUIDv7 affinity, Lite headers, and the Lite
developer-item payload shape. Legacy Codex models keep the original Responses
shape.

Knowledge tools were correctly registered but the engine-owned tool loop had
only inherited the working-folder TaskLocal. It now inherits the active agent,
project, session, and folder together, so grant checks can identify the caller.
Knowledge cards/details now show document and chunk totals and visibly report a
missing source folder or indexing error. The Memory Agents eye action now
delegates sheet presentation to the parent Memory view, and the project page's
two-column breakpoint was lowered for Rosy's usable Ventura window width.

Shared project transcripts are still immediate (`Recent Notes`). `Stored
Memory` remains deliberately asynchronous: it appears after the one-minute idle
debounce or when leaving the chat, after a successful distillation call. Opening
the preview does not trigger a surprise cloud request. Provider-qualified
routing fixes the model-resolution failure that could previously leave those
signals pending indefinitely.

Validation: focused acceptance regressions passed (**26 tests / 5 suites**).
The complete suite passed explicitly serially (**797 tests / 120 suites**). One
earlier all-at-once run crashed the Swift testing helper with signal 11; the
Codex fixture suite passed alone, and the explicit serial full rerun passed.

## M21 — Rosy acceptance repairs: Codex lifecycle and chat-window polish (2026-09-09)

Rosy's second M20 acceptance pass confirmed the substantive restoration: agent
models and provider ownership, Osaurus Router models, Codex catalog filtering,
Knowledge indexing/search/refresh/folder-loss reporting, project Knowledge,
working folders, project shared memory, Memory namespace inspection, and the
two-column project page all worked on the 2017 Intel machine.

The remaining Codex failure happened after valid text had already begun
streaming. The strict Intel Responses decoder treated
`response.content_part.done` as an unknown output event, replaced the partial
answer with an error, and therefore prevented follow-up/cancel/resume testing.
That event, along with the queued/content-part/reasoning-summary part lifecycle
markers, is structural protocol bookkeeping. The decoder now accepts those
known passive markers while continuing to reject unknown event types, unknown
output items, undisclosed tools, and non-completed terminal states. A fixture
pins the complete lifecycle around streamed text and a completed response.

Opening a stored conversation could also leave the header showing the
launch-time Default agent even though inference already used the conversation's
real agent. Intel's `ChatWindowState.loadSession` now adopts the stored agent
before publishing the restored session, refreshing the header, agent cache,
theme, and sidebar filter together. The change is covered by an isolated
storage test so it cannot touch a developer's real agents.

Two cosmetic Rosy-only defects came from the app shell. The chat content added
a second 24-point SwiftUI corner mask inside the native rounded window, exposing
gray wedges at the corners; Intel now trusts the native Ventura window mask and
keeps the underlying AppKit backing color synchronized with the active theme so
the antialiased edge cannot reveal a one-pixel gray crescent. The app
target now launches as a normal application and names `AppIcon` explicitly,
while `AppDelegate` still applies the user's Hide Dock Icon preference through
the runtime activation policy. The magnifying glass seen on upstream session
rows was not a missing control: it is the persisted Search capability badge,
derived from search tool calls in that conversation.

Validation: the Codex lifecycle suite passed **9 tests**; Intel session
hydration passed **3 tests**; the complete explicit serial run passed **799
tests in 120 suites**. The x86_64 package build and canonical signed Rosy app
build both passed. The final bundle targets macOS 13.0, carries `AppIcon.icns`,
uses `~/.osaurus`, and satisfies its designated signing requirement.

## M22 — Codex follow-ups and Claude Code folder browsing (2026-09-09)

Rosy's next acceptance pass exposed a role-sensitive Responses rule that a
single-turn fixture could not catch. The Intel adapter encoded every textual
message as `input_text`. That is correct for user and developer input, but a
completed assistant turn must be replayed as `output_text`; on turn two the
ChatGPT Codex backend rejected the assistant history with `Invalid value:
'input_text'. Supported values are: 'output_text' and 'refusal'.` The adapter
now emits `output_text` for assistant history and keeps `input_text` for new
user input. A three-message regression fixture pins the exact first-answer /
follow-up shape.

The Claude Code port's text-only behavior was also intentional code rather than
a CLI failure: it always selected `.textOnly`, passed `--tools ""`, discarded
decoded tool traces, and injected a system note saying tools were disabled.
When a chat has an explicitly selected working folder, the Intel service now
uses Claude's agent mode with the fail-closed `dontAsk` policy and allowlists
only `Read`, `Grep`, and `Glob`. Chats without a folder remain text-only. The
CLI still runs with the selected folder as its current directory, and its tool
activity is translated into the existing transient chat activity chip instead
of leaving a blank assistant row. Terminal token/rate statistics now reach the
normal chat telemetry path as well.

After reviewing the read-only build on Rosy, the user explicitly authorized
Claude Code to use `Edit`, `Write`, `NotebookEdit`, and `Bash` in a selected
working folder. Folder-backed Claude chats now allowlist those tools alongside
`Read`, `Grep`, and `Glob` under the same fail-closed `dontAsk` policy. The CLI
starts in the selected folder and its system note identifies that folder as the
workspace root. Chats without a selected folder remain text-only.

Validation: focused Codex/Claude/streaming coverage passed **35 tests in 3
suites** after replacing Intel's empty stats sentinel with the real wire
format. The complete explicit serial run passed **810 tests in 121 suites**.
The canonical Rosy x86_64 build passed and the final app satisfied its stable
designated signing requirement. After the mutation grant, the focused Claude
suite passed **10 tests**, the complete serial suite remained green at **810
tests in 121 suites**, and the canonical signed Rosy build passed again.
