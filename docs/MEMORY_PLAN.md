# Intel memory system — completion plan

Status date: 2026-09-05. Baseline: `1.0.34` (build 35), commit `62a73226`.
Recon artefacts: `R1-distillation.md`, `R2-substrate.md`, `R3-ui.md` (scratch).

---

## 0. Correction to the earlier framing

An earlier note in this project claimed "Intel memory is raw transcript recall only;
the distillation half is excluded." **That is wrong**, and planning against it would
have produced a large duplicate implementation.

`Services/Memory/MemoryService.swift` (upstream) *is* excluded — but the fork ships
its own **`Models/Chat/IntelConformers/IntelMemoryService.swift`** (652 lines,
compiled, wired). It implements the complete pipeline:

    bufferTurn → per-conversation debounce → one LLM call → episode + pinned facts
    + identity delta

Wiring is live: `ChatView.swift:2018` (buffer), `ChatWindowState.swift:226`
(flush on nav-away), `AppDelegate.swift:87,90` (init + orphan recovery). It resolves
a cloud model via `resolveDistillModel()` and calls `ChatEngine(model:).completeChat`
at temperature 0.2 / 1024 max tokens, parses a strict JSON digest, dedups pinned
candidates by Jaccard similarity (> 0.6), and appends identity facts.

**Consequence that matters more than the correction itself:** memory defaults to
`enabled = true` and `extractionMode = .sessionEnd`. Distillation has therefore
been running, and sending conversation turns to a cloud provider, on every build
that had a model configured. It is not a feature to add — it is a feature already
on, that nobody can see.

Second correction: **per-project memory needs no schema migration.** Upstream does
not add a `project_id` column. It reuses the existing `agent_id TEXT` column with a
`project-<uuid>` prefix, via the `MemoryNamespace` enum — which already exists in
this fork at `Models/Memory/MemoryModels.swift:469-499`, byte-identical to upstream
and entirely unreferenced. The earlier "highest-risk migration in the codebase"
warning does not apply.

---

## 1. What actually exists, what is actually missing

### Works today
- Distillation pipeline (`IntelMemoryService`), incl. novelty gate, dedup, telemetry.
- `MemoryDatabase` (2725 lines, SQLCipher, schema v9) with all tables and every
  decay/evict/prune method already implemented.
- Embedding stack — `potion-base-8M` static embedder, downloaded on first use.
  This is the *retrieval* half; it does not summarise anything.
- Recall: four-layer budgeted assembly (identity → pinned → episodes → transcript),
  injected as its own system message before the last user turn.
- Memory settings UI: a 268-line four-card panel (`MemoryView.swift:1077-1345`).

### Genuinely missing
| Gap | Nature | Severity |
|---|---|---|
| Consolidation never runs | `MemoryConsolidator` excluded, no Intel equivalent. Decay, dedup-merge, promotion, eviction and transcript pruning **never execute**. Facts accumulate forever. | **High** — unbounded growth, recall quality decays over time |
| No visibility | No Identity view, no memories browser, no diagnostics, no stats. Distillation succeeds or fails invisibly. | **High** — cannot verify the thing works |
| `assembleContext` is a stub | `IntelDataConformers.swift:537` hard-returns `nil`, silently zeroing the memory-token estimate in the context-budget popover. | Medium — display bug, does not affect recall |
| Recall ignores agent scoping | `composeChatContext` passes `agentId: nil` deliberately; every agent recalls every other agent's memories. | Medium — by design, but undocumented in UI |
| No project namespace wiring | `MemoryNamespace` exists, unused. No namespace count queries, no `deleteNamespaceData`. | Medium |
| `relevanceGateMode` inert | Setting exists, nothing reads it. | Low |
| Recall re-embeds every turn | No cache (the excluded assembler had a 10s TTL). | Low — perf only |
| Danger Zone skips confirmation | Clears immediately; upstream confirms first. | Low, trivial |

---

## 2. Decisions taken

- **Distillation stays cloud-based, but becomes opt-in per agent, default off.**
  This is a *behaviour change from today*, where it is on by default. The Memory
  settings tab must name the provider that receives turns.
- **Ventura testing is deferred, but the Ventura constraints stay.** Build to the
  macOS 13 SDK; no macOS 14+ API; no SF Symbol that does not already render
  somewhere in this fork. Dropping these is a one-way door and has not been decided.

---

## 2b. Guiding principle — mirror upstream

**Port upstream's implementation; do not design a replacement.** Where upstream code
exists for a surface, lift it: preserve its structure, ordering, labels, copy, spacing
and component choices. Fidelity beats taste. This fork's value is being *Osaurus on
Intel*, not a variant of it.

For the memory UI the best source is often already in-tree: `MemoryView.swift` and
`MemoryComponents.swift` each contain upstream's full implementation in a dead
`#if !OSAURUS_INTEL` half. Lift from there first; if the fork's snapshot looks older
than current upstream, check `git show upstream/main:<path>` and prefer the newer shape.

Only hard constraints override fidelity, and every deviation must be stated:
- macOS 13 — the two-parameter `onChange(of:)` must become single-parameter.
- SF Symbols must already render in this fork's `Views/` tree.
- Anything bound to an excluded service cannot ship live.

**One deliberate divergence stands** (owner's decision, 2026-09-05): distillation becomes
opt-in per agent, default OFF, where upstream defaults it on. This is a privacy choice,
not an oversight — it must not be "corrected" toward upstream by a later lane. Pair it
with a discoverable off-state; a silent default-off is how this fork's silent-dead-feature
bugs happen.

---

## 3. Phases

### Phase 1 — Make it visible and honest (do first)
Nothing else is verifiable until the pipeline can be observed.
1. Intel diagnostics service + revived Diagnostics UI: pipeline status, core-model
   availability, pending/processed/dead signal counts, distillation results,
   `bufferTurn` telemetry, recent `processing_log`.
2. Identity card (view + edit + overrides add/remove) — data source already live.
3. Statistics card — `processingStats()` / `databaseSizeBytes()` already live.
4. Fix the `assembleContext` stub so the budget rail stops lying.
5. Danger Zone confirmation.

### Phase 2 — Consolidation (the real backend gap)
Intel `MemoryConsolidator` equivalent + scheduling. All `MemoryDatabase` methods it
needs already exist. Pure logic, no LLM. Plus a manual "Run Now".

### Phase 3 — Opt-in distillation
Move distillation behind a per-agent opt-in, default off, with provider disclosure.
Sequenced after Phase 1 so the diagnostics can prove the gate works.

### Phase 4 — Memories console
The largest surface (~2150 lines upstream): search, scope filter, agent filter,
inspect, disable, forget, context preview.

### Phase 5 — Project memory
`MemoryNamespace` wiring at write sites, `projectNamespaceCounts()` /
`agentNamespaceCounts()` / `deleteNamespaceData()` on `MemoryDatabase`, and the
Projects section in the Agents tab. No migration required.

---

## 3b. Backlog (raised during testing, not yet scheduled)

- **Chat export on Intel.** Removed from both menus in 1.0.34 because
  `ChatSessionExportCoordinator` and `ExportChooserSheet` are excluded, so it
  could never work. Owner wants it back — that means an Intel export path, not
  just restoring the menu entry.
- **Upstream's fuller project page.** This fork's project page is a
  single-column instructions + chat list. Upstream's is a richer two-column
  layout; port it, minus the amputated Knowledge dimension.
- **Memories console gaps** (from the Phase 4 port, each needs a
  `MemoryDatabase` change first): per-row disable — nothing here ever writes a
  status other than `active`; per-turn transcript forget — only
  `deleteTranscriptForConversation` exists; the storage-health panel — no public
  schema-version accessor; the context preview's query field — the Intel
  assembler takes no query by construction.
- **Per-agent recall scoping.** Recall passes `agentId: nil`, so every agent
  recalls every other agent's memories. Deliberate and documented, but worth
  revisiting now that project scoping exists.
- **Should an opted-out agent still feed its project's pool?** Upstream says
  yes. Deliberately not ported — it is a values question, not a code one.

---

## 4. Standing constraints

- Check `Package.swift`'s `exclude:` list before reasoning about any file.
- Never add a non-optional stored property to a persisted `Codable` type.
  `MemoryConfiguration` already has a tolerant `decodeIfPresent` decoder — extend it.
- macOS 13 target. Upstream's memory UI uses the **two-parameter** `onChange(of:)`
  (macOS 14+) uniformly — every ported instance must become single-parameter.
- SF Symbols must already render somewhere in this fork's `Views/`. Upstream's memory
  UI uses several that do not: `chart.bar`, `doc.text.magnifyingglass`, `pause.circle`,
  `person.2`, `person.text.rectangle`, `rectangle.and.text.magnifyingglass`,
  `syringe`, `tray.and.arrow.down`. `rectangle.and.text.magnifyingglass` sits right
  at the macOS 13 cutoff and is the highest blank-render risk — substitute it.
- Gates: `swift build --arch x86_64`, `swift test --no-parallel` (698/102),
  `xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -arch x86_64
  -skipPackagePluginValidation -skipMacroValidation ... CODE_SIGNING_ALLOWED=NO`.
- Release: `intel-fork` must be fast-forwarded and pushed BEFORE `cut_intel_release.sh`.

---

## 5. Service contract for Phase 1 (so UI and service can be built in parallel)

New file `Models/Chat/IntelConformers/IntelMemoryDiagnostics.swift`:

    @MainActor public final class MemoryDiagnostics: ObservableObject {
        public static let shared: MemoryDiagnostics
        @Published public private(set) var snapshot: MemoryDiagnosticsSnapshot?
        public func refresh() async
    }

    public struct MemoryDiagnosticsSnapshot: Sendable {
        public let memoryEnabled: Bool
        public let databaseOpen: Bool
        public let extractionMode: String
        public let coreModel: String?          // nil => unavailable
        public let coreModelDetail: String?    // remediation text when nil
        public let pendingSignals: Int
        public let processedSignals: Int
        public let deadSignals: Int
        public let allTimeSignals: Int
        public let distillOK: Int
        public let distillSkipped: Int
        public let distillErrors: Int
        public let distillEmpty: Int
        public let distillDead: Int
        public let episodeCount: Int
        public let pinnedFactCount: Int
        public let bufferAttempts: Int         // 0 => bufferTurn never invoked
        public let databaseBytes: Int64
        public let recentLog: [MemoryProcessingLogEntry]
        public let perAgent: [MemoryAgentDiagnostic]
    }

`MemoryProcessingLogEntry` and `MemoryAgentDiagnostic` are defined by the service
lane; the UI lane binds to them by the field names above.
