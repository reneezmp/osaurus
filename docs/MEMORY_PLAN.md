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

---

# Test results — 2026-09-07, build `1.0.34-memory-test3` (Ventura + Sequoia)

Commits under test: `bd7b085d`, `3e11f3fb`, `b84c8f6a`, `8d9233c6`, `b0b7a798`,
`029d3f80`, `e036ea97`, `00e6c0fd`.

## Passed

- Memory tab fidelity, all four reported differences closed: tab counts +
  Diagnostics badge, Agents tab row layout, Diagnostics card layout, per-agent
  `on` / `off (this agent)` + Enable.
- Distillation opt-in, Identity tab, Memories console, Agents tab, project-scoped
  memory, consolidation run — all working.
- **Ventura passed everything**, including the new Agents/Diagnostics iconography
  and the five-tab bar with counts. No blank symbols, no List-spacing gaps.
- Regression: project route, New Chat in project, back-chip, agent picker,
  settings gear, New Chat all fine.
- The memory rail now appears in the context budget **for an existing chat**.

## Open defects

### D1 — Toolbar item clips the agent pill (HIGH, blocks the toolbar work)
Symptoms: only part of the pill renders; shrinking the chat area makes it vanish
entirely; collapsing the sidebar makes it render fully.

Root cause CONFIRMED. `IntelChatToolbarDelegate.host(_:_:)`
(`ChatWindowManager.swift:1257-1258`) sizes the hosting view **once**, at
creation:

    let hosting = NSHostingView(rootView: rootView)
    hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

That frame is never recomputed. The chat-area centring added in `00e6c0fd`
applies `.offset(x: sidebarWidth / 2)`, which moves content **outside** that
fixed frame, so it is clipped — and the frame was measured before the project
chip existed, so the combined chip+pill is wider than the box it lives in.

The `.offset` approach is therefore incompatible with a fixed-size
`NSHostingView`. Options for next session, in rough order of preference:
1. Let the hosting view size itself (Auto Layout / `translatesAutoresizing…
   = false`), so the frame tracks its content, and express the shift as leading
   padding rather than an offset — padding grows the frame, an offset does not.
2. Recompute `hosting.frame` when the content changes (needs a size-change
   signal out of SwiftUI; fragile).
3. Abandon chat-area centring, keep the combined chip+pill, accept
   window-centring. Loses the fix but is stable.

### D2 — Project page header collides with the window controls (HIGH)
On the project page the page's own header (back chevron, folder glyph, title,
rename pencil) draws over the traffic lights. The toolbar items are correctly
hidden there, which leaves the titlebar strip empty, but the page content starts
at y=0 and runs underneath it. Needs a top inset for the titlebar height on that
route.

### D3 — Clicking a sidebar chat while on the project page does nothing (HIGH)
CONFIRMED at `ChatContentView.swift:156`:

    onSelect: { [weak windowState] data in windowState?.loadSession(data) },

It loads the session but never clears `openProjectId`, so the route stays on the
project page and the click appears to do nothing. Every other exit from the
project page clears it; this one was missed. One-line fix.

### D4 — Memory rail absent on the welcome screen (MEDIUM)
It appears in an existing chat, but not in the pre-first-message budget. The
welcome path goes through `from(context:)`, whose `composed.memorySection` is nil
before there is a query to recall against, and `cachedMemoryTokens` — which
exists precisely to estimate this case — is not threaded into that path. Either
route the welcome preview through the manifest overload, or have `from(context:)`
fall back to the cached estimate when `memorySection` is nil.

### D5 — Episode merge threshold is very slightly too strict (MEDIUM)
The instrumentation answered it on the first run:

    merged=0 … [merge: considered=27 embedded=27 bestSim=0.89 threshold=0.9]

Embeddings are fine — 27 of 27 episodes carry vectors. The most similar pair
scored **0.89** against a **0.90** threshold.

`episodeMergeCosineThreshold = 0.9` is inherited verbatim from upstream, but
upstream computes similarity with a different embedder (MLX, 768-dim) while this
fork uses the 256-dim `potion-base-8M` static model. Cosine distributions are not
comparable across embedding spaces, so the constant should not have been
inherited unexamined. Do NOT simply lower it to 0.85 by feel — gather a few more
`bestSim` samples first, and consider making it configurable.

### D6 — Identity overrides accumulate near-duplicates (MEDIUM, newly found)
Observed in the live overrides list: *"The user's name is Renée."* and *"User's
name is Renée."* both present; three overlapping Brisa entries; four overlapping
entries about the 2017 MacBook and the M4.

`IntelMemoryService.applyIdentityDelta` dedupes case-insensitively on **exact**
string match, so paraphrases always survive. Consolidation never touches identity
overrides at all. Check what upstream does here before designing a fix; the
Jaccard helper already used for pinned-fact dedup is the obvious candidate.

### D7 — `/agent` starts a new chat instead of switching the current one (MEDIUM)
The picker opens and a selection can be made, but it opens a blank session with
that agent rather than re-assigning the open conversation. Confirm upstream's
intended semantics before changing behaviour — this may be upstream's design.

## Decisions taken

- The Memories console's "Include disabled" toggle stays absent. Confirmed by the
  owner rather than assumed.

## Suggested order for the next session

1. D3 (one line), then D2 — both make the project route usable again.
2. D1 — decide between the three options above before writing code.
3. D4.
4. D5 with more samples; D6; D7 after checking upstream.


## Follow-up implementation — 2026-09-07 (unreleased)

The original test report above is preserved. Current follow-up status:

- **D3 patched:** sidebar selection clears `openProjectId` before loading the
  selected session.
- **D2 patched:** project content reserves the hosting window's measured
  titlebar exclusion, rather than assuming a fixed height. Runtime verification
  on both supported boots remains required.
- **D1 patched, option 1 selected:** the toolbar hosting view publishes its
  intrinsic size, and full-sidebar-width leading padding replaces the half-width
  offset. Because the complete item is window-centred, that padding moves its
  visible content by half the sidebar width. A disposable native-window harness
  verified host resizing as an ordinary project chip appears and an agent label
  grows. Oversized items remain subject to normal toolbar compression; both-boot
  app checks with narrow windows and long labels remain required.
- **D4 patched:** the Intel welcome preview passes its cached memory estimate to
  the context breakdown. Actual composed memory takes precedence, including an
  explicitly empty section. Initial session creation now refreshes estimates
  independently of model discovery; the old `applyInitialModelSelection` caller
  was in the inactive non-Intel window-state branch.
- **D5 remains open:** no additional persisted `bestSim` samples were available
  in the inspected local logs/backups; the Intel development data root was absent.
  Keep the threshold at **0.90**. Collect additional distinct corpus snapshots or
  pair-score distributions before tuning; repeated runs over identical vectors
  are not independent evidence.
- **D6 partially addressed:** conservative identity normalization handles case,
  whitespace, typographic punctuation, and the introductory article in user facts.
  Distillation deduplicates within a batch against the latest stored identity;
  consolidation removes the same safe duplicate forms. Database mutations are
  atomic and preserve the retained original text/order. Broader semantic overlaps
  remain open: Jaccard alone can discard different values or negated facts, so no
  fuzzy threshold or model-based cleanup is introduced.
- **D7 resolved as upstream intent, unchanged:** local upstream reference
  `098cbd4ed1e9a6ae496bc342f3cd9f168394d65c`,
  `Managers/Chat/ChatWindowState.swift:307`, explicitly starts a fresh chat when
  switching agents. `/agent` opens the same picker; it does not reassign the
  current conversation. Changing that behavior would be a deliberate divergence.

Validation for this follow-up:

- `swift build --arch x86_64` — passed.
- `swift test --no-parallel` — **707 tests / 104 suites passed**. One prior run
  hit the documented `LiveExecRegistryTests.entriesPublisherEmitsOnRegister`
  timing flake; the full rerun passed without changes to that test.
- `xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug
  -arch x86_64 -skipPackagePluginValidation -skipMacroValidation
  -derivedDataPath build/rosy-deploy ONLY_ACTIVE_ARCH=NO
  MACOSX_DEPLOYMENT_TARGET=13.0 CODE_SIGNING_ALLOWED=NO build` — passed.
  The resulting app's Mach-O metadata confirms `minos 13.0`.
- `git diff --check` — passed.
- Both-boot visual verification is still pending for these new changes.

The identity list also deletes by the displayed original text, so cleanup shifting
indices cannot make a stale row action delete a different fact. Regression tests
cover this alongside fallback precedence, empty composed memory, identity batch
deduplication, retained text/order, and metadata preservation.
