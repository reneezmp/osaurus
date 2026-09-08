# Sync plan: upstream `0.20.3` → `0.24.3`

**Written:** 2026-09-02 (Session 11)
**Scope:** `9124d696..4528b56f` — 783 upstream commits, 476 reviewed, **211 PORT candidates**
**Inputs:** [`UPSTREAM_SYNC.md`](UPSTREAM_SYNC.md) (triage summary) · [`UPSTREAM_TRIAGE_0.24.3.md`](UPSTREAM_TRIAGE_0.24.3.md) (per-commit verdicts)
**Status:** completed through the staged execution recorded in `UPSTREAM_SYNC.md`

---

## 1. The strategic call

Do **not** attempt a single 783-commit sync, and do **not** attempt 211 sequential
cherry-picks. Both fail for the same measured reason (§2): the fork's hot files have
diverged by *deletion*, while upstream's same files have grown by thousands of lines.
Cherry-picks into them will conflict on almost every hunk, and a "successful" merge is
more dangerous than a failed one because it silently re-imports amputated code.

Instead: **three different porting mechanisms, chosen per file, executed in three releases.**

The first release is deliberately out of chronological order — a small hand-ported hotfix
set that pays for the whole effort immediately. Everything after it runs chronologically
by window, which is the only ordering that keeps cherry-picks sane.

### Decisions taken (Renée, 2026-09-02)

| Question | Decision |
|---|---|
| `311d9095` storage encryption | **Backlog** — revisit after everything else lands (§10) |
| `8a9d32ea` Projects | **Tackle it fiercely.** The feature that motivated this sync. Centerpiece of Release 3 |
| Wave C scope | **52 PORT-touched files first, compiler-expanded** — evidence in §4 Release 2 |
| Cadence | **Three releases**, not six |

---

## 2. Measurements that shape this plan

Three facts, all measured on 2026-09-02, not assumed.

### 2.1 — 307 of 783 commits are mechanically dead

Classified by intersecting each commit's touched files with the 164-path `exclude:` list
in `Packages/OsaurusCore/Package.swift`. No judgment involved, so this number is trustworthy:
92 IGNORE (docs/CI/appcast/i18n/evals) + 90 NEW-SUBSYSTEM (files absent from the fork) +
76 INFRA-ONLY (vmlx repins, `Package.resolved` churn) + 49 SKIP (exclude-list-only).

### 2.2 — Only 107 of 339 live files are pristine

Of the files the Intel target compiles **and** that reviewed commits touch:

| Class | Count | Meaning |
|---|---:|---|
| **Pristine** | 107 | byte-identical to upstream `@9124d696` → safe to fast-forward wholesale |
| **Intel-touched** | 232 | diverged → must be hand-reconciled |

The pristine files are the cheapest win available — but **not all 107 should be taken**. Only
52 of them are touched by a PORT-verdict commit; the other 55 are touched only by SKIP/DEFER
commits, meaning their upstream delta is amputated-feature code. See §4 Release 2, Wave C.

### 2.3 — Intel divergence is amputation; upstream growth is addition

| File | Intel drift vs base | Upstream moved | `OSAURUS_INTEL` guards |
|---|---|---|---:|
| `ChatView.swift` | **+997 / −2718** | +6047 / −767 | 6 |
| `FloatingInputCard.swift` | +176 / −697 | +5552 / −1328 | **0** |
| `HTTPHandler.swift` | +503 / **−10014** | +2997 / −207 | **0** |
| `AppDelegate.swift` | +545 / −1886 | +771 / −166 | 2 |
| `SystemPromptTemplates.swift` | +49 / −267 | +1045 / −124 | 2 |
| `NativeMessageCellView.swift` | +72 / −507 | +865 / −60 | **0** |

This table is the heart of the plan. It says:

1. **Re-baselining is impossible for these files.** Taking upstream's 0.24.3 `ChatView`
   imports 6047 lines that reference amputated subsystems. Same for the rest.
2. **The conflict burden is concentrated, not spread.** `ChatView.swift` alone is touched
   by **132 of the 476** reviewed commits; `FloatingInputCard` 78; `HTTPHandler` 58.
   Roughly six files carry most of the pain.
3. **⚠️ Three of the six have zero `OSAURUS_INTEL` guards.** Their amputation was done by
   raw deletion. This is a live hazard: the existing revert-detector only finds files that
   *lost all their guards*, so it is structurally blind to `FloatingInputCard`,
   `HTTPHandler`, and `NativeMessageCellView`. A cherry-pick can re-import amputated
   references into them and no tripwire fires. See §6.3 for the mitigation.

---

## 3. The three mechanisms

Pick per file, not per commit.

| # | Mechanism | Use when | Command shape |
|---|---|---|---|
| **FF** | Fast-forward the whole file | file is **pristine** (§2.2) and not on the Intel-owned list | `git checkout upstream/main -- <path>` |
| **CP** | Cherry-pick the commit | commit touches only Intel-touched files with *small* drift, and applies cleanly | `git cherry-pick -x <sha>` |
| **HP** | Hand-port the semantic change | commit touches a hot amputation-scarred file (§2.3), or CP conflicts | read `git show <sha>`, write the equivalent change by hand |

**Rule:** if a cherry-pick conflicts inside one of the six hot files, do **not** resolve the
conflict. Abort and switch to HP. Resolving a conflict in an amputated file is how upstream
code gets silently re-imported.

**Rule:** never FF a file on the Intel-owned list in `UPSTREAM_SYNC.md` §*Intel-owned files*
(README, the two keychain service names, `Info.plist`, release/build scripts).

---

## 4. Execution plan — three releases

| Release | Name | Contents | Dominant mechanism |
|---|---|---|---|
| **`1.0.32`** | Stabilize | Wave A (hotfixes) + Wave B (crashes/hangs) | HP + CP |
| **`1.0.33`** | Modernize | Wave C (pristine fast-forward) + proxy/MCP | FF + CP |
| **`1.0.34`** | **Projects** | Wave D (chat QoL, Projects as centerpiece) | HP |

Backlog after the sync: storage encryption, deferred-shelf re-triage (§10).

---

### Stage 0 — Safety net (do first, no exceptions)

```bash
cd ~/Developer/osaurus
git stash push -- Packages/OsaurusCore/Services/Inference/FoundationModelService.swift  # never commit this
git tag pre-sync-0.24.3 intel-fork       # rollback anchor + tripwire baseline
git checkout -b sync/0.24.3              # all work happens here; intel-fork stays clean
cd Packages/OsaurusCore && swift build --arch x86_64   # MUST be green before starting
```

Record the baseline build time and warning count. If the tree is not green *before* the
sync, every later failure is ambiguous. Then capture the guard baseline:

```bash
git grep -l OSAURUS_INTEL pre-sync-0.24.3 -- '*.swift' | sed 's/^[^:]*://' | sort -u > /tmp/guards.base
```

---

## Release 1 — `1.0.32` "Stabilize"

Smallest surface, highest immediate value, independent of everything else. Can start now.

### Wave A — Hotfix set (hand-ported, out of order) 🔴

**Why first:** these are actively costing you on Rosy. They are small, and hand-porting
sidesteps the prerequisite problem entirely — no need to have landed windows 1–3.

| Commit | What | Mechanism |
|---|---|---|
| `984debe2` | harden keychain on relaunch + identity restore from recovery phrase | HP |
| `e06996e3` | surface specific keychain errors, recover ACL-denied credential saves | HP |
| `5f12d260` | remote-provider hardening: crashes, hangs, endpoint trust, **Router spend safety**, streaming | HP |
| `563f9174` | Router 409 idempotency on refunded iterations | CP→HP |
| `0a8c5008` | external providers stuck disconnected after an update relaunch | CP |
| `f9478c0f` | lenient decode for nonstandard streaming chunks during tool calls | HP |
| `577a3eee` | honor context windows from custom providers | CP |

### Wave B — Crash & hang fixes (chronological CP) 💥

`03ea4c93` · `cc6732d7` · `161e6ca5` · `dfd412f6` · `0d07b052` · `286c4a9a` · `3ba84c38` ·
`2eac8d32` · `c8be96cc` · `99537680` · `6daf54cb`

Sentry-triaged generic AppKit/SwiftUI fixes. Cherry-pick in commit order. Expect
`AppDelegate.swift` conflicts (46 commits touch it) — those go HP.

**Exit criteria (both waves):** Ventura build green · keychain does not re-prompt across a
relaunch on Rosy · a real billed Router completion succeeds · a malformed streaming chunk does
not abort the turn · app survives repeated settings open/close, management sheet swaps, a long
chat scrolled with the find bar open, and a display reconfigure.

---

## Release 2 — `1.0.33` "Modernize"

The infrastructure release. Release 3 depends on it, so it must not be skipped.

### Wave C — Pristine-file fast-forward 🎁

**Scope decision — take the 52, let the compiler expand it.**

Of the 107 pristine files (§2.2), the join against per-commit verdicts says:

| Pristine files | Count | Their upstream delta is… |
|---|---:|---|
| touched by ≥1 **PORT** commit | **52** | wanted work → fast-forward |
| touched by **no** PORT commit | 55 | only SKIP/DEFER commits — i.e. **amputated-feature code** |

That second row is the whole argument. A pristine file touched only by SKIP commits has an
upstream delta that consists of the very subsystems this fork amputates. Fast-forwarding it
imports amputated-feature code into a *compiled* file — which either fails the build (visible,
fine) or silently reaches an `IntelStubs` no-op (invisible, the exact §6.3 hazard).

So: **fast-forward the 52, build, and let the compiler name which of the 55 must follow** for
API drift. Add those one at a time, reading each diff. Minimum necessary set, empirically
expanded — not a guess in either direction.

```bash
scripts/sync/list_pristine.py 9124d696 --triage /tmp/t.json   # emits the list
git checkout upstream/main -- <path>                          # per file
cd Packages/OsaurusCore && swift build --arch x86_64
```

Highest-value files in the 52 include `Services/Router/OsaurusRouterAPIClient.swift`,
`Services/Router/RouterBillingLedger.swift`, `Models/Theme/CustomTheme.swift`,
`Views/Chat/PastedContentSheet.swift`, `Services/ModelOptionsStore.swift`.

⚠️ This wave carries **the largest Ventura backport burden** of the whole sync (§5). Do it as
its own commit series so it can be reverted independently.

---

#### Outcome (executed 2026-09-02) — the premise was half wrong

**Result: 50 selected → 33 landed. Build green, all gates pass.** Seventeen files had to be
reverted, and the reason matters for Release 3's planning:

> **Pristine ≠ independent.** A file can be byte-identical to upstream at the sync base and
> *still* be un-fast-forwardable, because upstream evolved it in lockstep with files this fork
> owns and has diverged. Taking half of a coupled group breaks the build.

Concretely, the seventeen fell into four kinds:

| Kind | Example | Why reverted |
|---|---|---|
| Needs a module the fork lacks | `GlobalProxyConfiguration.swift` | upstream extracted `Packages/OsaurusNetworking`; adopting it is a real decision, not a fast-forward |
| Companion file is fork-owned | `OsaurusRouterAPIClient.swift` | its types live in `OsaurusRouterTypes.swift`, which Wave A modified for the DEBUG-lock |
| Pulls in amputated-feature types | `ToolPermissionPromptService.swift` (`KnowledgeWritePreview`), Router cloud image/video/web-search types | the feature does not exist here |
| Upstream deleted something the fork still uses | `BackgroundTaskModels.swift` (`BackgroundTaskStatus.awaitingClarification`) | upstream removed it *and* updated its consumers; ours are fork-owned and diverged |

Also **deliberately declined**: `Models/SystemPermission.swift`, which adds
`.automationMessages`. That permission exists to serve the amputated iMessage channel; adopting
it would have meant inventing a Messages permission flow for a feature the fork does not ship.

**Two hand-reconciliations were worth doing rather than reverting:**
1. `IdentityView.swift` — rewired to the fast-forwarded `RecoverFromMnemonicSheet`, whose new
   signature (`mode:` + `(OsaurusIdentity.RestoreResult) -> Void`) matches the `restore(words:)`
   backend Wave A ported. **This closes Wave A's "backend with no UI" gap** — identity restore is
   now reachable, and reports re-derived agents, revoked access keys and per-item failures.
2. `ChatView.swift` — supplied `isBlocked: false` to `InlineCompleteBlock`; the badge
   distinguishes an agent run halted for approval, which cannot occur here.

**Lesson for Release 3.** Wave D₀ (Projects) is a rebuild against fork mirrors, and this wave
confirms why: the coupling between upstream's files and this fork's owned files is the dominant
constraint, not the individual file's contents. Budget for reconciliation, not transcription.


### Wave E′ — Proxy & MCP (storage encryption removed to backlog) 🗄️

`304ad2bb` + `0ba6a01a` + `52d4aa9b` (global proxy — continues the 1.0.24 batch, so the
`makeSession()` mapping rule from `UPSTREAM_SYNC.md` still applies) · `774aa836` (MCP session
recovery + OAuth single-flight) · `3f4791e7` (paginated tool discovery) · `12ff17c7` (bearer
401) · `f5009855` (MCP URL detection) · `9ddb49b0` (migration hardening)

Small and mostly clean; rides along with C.

**Exit criteria:** build green at macOS 13 · revert-detector clean · `tripwire.sh` clean ·
every new icon visually checked **on Rosy** (§5) · a smoke chat reaches no stub no-op.

---

## Release 3 — `1.0.34` "Projects" 🌟

### Wave D₀ — Projects (`8a9d32ea`) — the golden feature

> **Reality check: this is not a port, it is a feature build.** Upstream's commit touches 40
> files, but the feature's entire spine is on the fork's `exclude:` list —
> `ChatSessionsManager`, `ChatSessionStore`, `ChatSessionData`, `SystemPromptComposer`,
> `ComposeRequest`, `AgentConfigSnapshot`, `MemoryService`, `MemoryContextAssembler`,
> `MemorySearchService`, `ChatHistoryDatabase`. A cherry-pick is not available. Treat
> `8a9d32ea` as a **reference design** and rebuild it against the fork's Intel mirrors.

Two structural findings, both verified 2026-09-02:

1. **Drop the knowledge dimension.** The diff mentions `knowledge` 154 times and two of its 40
   files are Knowledge-only (`Views/Knowledge/KnowledgeView.swift`, `Tools/KnowledgeTools.swift`).
   The Knowledge base is amputated. **Intel Projects = shared instructions + memory + chat
   grouping.** Upstream's "project knowledge collections wired into chat grant scope" is
   explicitly out of scope; do not try to stub it.
2. **No schema collision.** Upstream bumps `ChatHistoryDatabase.latestSchemaVersion` 14 → 15,
   but that file is **excluded** in the fork, so nothing collides. The fork's own
   `MemoryDatabase` is on its own line (currently **v9**). Consequence: project membership must
   be added to the fork's *own* chat-session persistence (the `IntelDataConformers` mirror),
   with its own migration step — not inherited.

**Sub-plan (each step independently buildable):**

| Step | Work | Notes |
|---|---|---|
| **P1** | `Project.swift`, `ProjectStore.swift`, `ProjectManager.swift` | New files with no fork counterpart — take upstream's nearly as-is |
| **P2** | Project membership on the Intel chat-session mirror + migration | The fork-specific part; upstream's v15 step is the reference, not the code |
| **P3** | Sidebar: chats/projects tab bar, move-to-project popover | `ChatSessionSidebar.swift` + `SharedSidebarComponents.swift` — HP |
| **P4** | Instruction injection into chat context | Use the Intel `SystemPromptComposer` mirror — the **same `composeChatContext` → inject-prefix path the memory recall already uses**. Cache-safe. |
| **P5** | `ProjectDetailView`, `ProjectNamePromptSheet`, `AddChatsToProjectSheet` + detail search | Mostly new files; `ChatView.swift` hookup is HP |
| **P6** | Back-to-project toolbar button, hide agent pill/window pin on project page | Pure `ChatView` polish — HP, do last |

**Exit criteria:** create a project, move chats into it, project instructions demonstrably reach
the model (verify the same way memory recall was verified — the model quotes them), membership
survives a relaunch, and the Ventura layout is checked **on Rosy**.

### Wave D₁ — The rest of chat QoL 💅

`5ada76dc` (full-text search + ⌘F) · `6ae20356` (pin chats) · `479133ba` (multi-select
delete/archive) · `5bb946f7` (auto titles) · `3580502c` (`/title`) · `311f327c` + `48c6d197`
(import from ChatGPT/Claude/Grok) · `c4d9d140` (delete individual messages) · `035ed272`
(resizable sidebar) · `e0eeba12` (⌘N) · `1b955c2b` (⌘±) · `f3608d88` + `8a8f01ec` (inline +
display LaTeX) · `08eb8bd8` (escape no longer eats the prompt) · `ce414b3f` (LLM context
compaction) · `96b05d20` (hide local-memory warnings for cloud models)

Nearly all land in `ChatView.swift` / `FloatingInputCard.swift` → **expect HP, not CP**. Take
them in window order (W1→W5); this is the slowest wave per commit. `5bb946f7` before `3580502c`.
## 5. Ventura (macOS 13) backport pass

Runs **after every wave**, not once at the end. Three upstream minor releases of new API
usage are in this range; the existing pattern table in `UPSTREAM_SYNC.md` §*Ventura backport
maintenance* covers `@Observable`, two-arg `onChange`, `.symbolEffect`, `.activateAllWindows`.

New categories to expect from a 0.21→0.24 jump (verify, don't assume):
`ScrollPosition` / `.scrollTargetBehavior` · `ContentUnavailableView` · newer SF Symbols that
render blank on 13 (the `brain.head.profile.fill` failure mode — **blank, not a build error**,
so the compiler will not catch these) · Swift 6 concurrency annotations.

```bash
cd Packages/OsaurusCore && swift build --arch x86_64
```

⚠️ The SF Symbol class is invisible to the build. After each wave, **visually** check every
new icon on Rosy, not on the M4.

---

## 6. Verification gates

Every wave must pass all four before it ships.

### 6.1 — Ventura build
`cd Packages/OsaurusCore && swift build --arch x86_64` — zero errors.

### 6.2 — Revert-detector (existing)
```bash
comm -23 /tmp/guards.base \
  <(git grep -l OSAURUS_INTEL HEAD -- '*.swift' | sed 's/^[^:]*://' | sort -u)
```
Any output = a file lost all its Intel guards. Investigate before shipping.

### 6.3 — Amputation-drift tripwire (`scripts/sync/tripwire.sh`, written + tested)

```bash
scripts/sync/tripwire.sh pre-sync-0.24.3
```

Reports line-count drift and guard counts for the six amputation-scarred files (§2.3),
and fails when one grows by more than 40 lines or loses all its `OSAURUS_INTEL` guards.

> **A rejected design, recorded so it is not re-attempted.** The obvious version of this
> check — grep the compiled sources for amputated type names — **does not work**, and was
> discarded after testing. Two reasons: (a) the fork provides Intel *conformer mirrors* for
> many excluded types (`MemorySearchService`, `AgentManager`, `ServerController`, …), so
> referencing them is correct and the grep is drowned in false positives; (b) a symbol with
> no mirror at all simply fails to compile, so `swift build --arch x86_64` **already is**
> the undeclared-symbol check. Do not re-add a symbol grep.
>
> Two further traps found while testing it, both of which cause a **silent vacuous pass**:
> `git grep -E` does not support `\b` word boundaries (use `-P`), and a
> `Packages/OsaurusCore/**/*.swift` pathspec matches zero files under git's default
> pathspec rules (use a plain directory pathspec). Any check written here must be
> negative-controlled — inject a fake violation and confirm it fails — before it is trusted.

The risk this actually mitigates is the one the compiler cannot see: re-imported upstream
code that compiles fine but calls into an `IntelStubs` no-op. Size is the reliable proxy —
these files should not grow during a sync. Growth is a prompt to read the diff, not a verdict.

### 6.4 — Intel-owned file audit
Walk the table in `UPSTREAM_SYNC.md` §*Intel-owned files & post-sync verification*. All seven
rows, every wave. The README and the keychain service names have been silently reverted before.

### 6.5 — Live smoke on Rosy
Not the M4. A real chat turn through the Osaurus Router (billed), a DeepSeek turn, a memory
recall, and a settings walk-through. The M4 cannot detect Ventura layout gaps or blank symbols.

---

## 7. Tooling (written and verified 2026-09-02)

All three already exist on `intel-fork` and reproduce the numbers in this document:

1. **`scripts/sync/triage.py`** — the deterministic classifier from §2.1. Parses the
   `exclude:` list out of `Package.swift`, buckets a commit range, emits the REVIEW set.
   **The single biggest time-saver — it eliminated 39% of the work before any judgment.**
   ```bash
   scripts/sync/triage.py 9124d696 upstream/main --json /tmp/t.json
   # -> 783 commits: REVIEW 476, IGNORE 92, NEW-SUBSYSTEM 90, INFRA-ONLY 76, SKIP 49
   ```
2. **`scripts/sync/list_pristine.py`** — the §2.2 classifier; emits the fast-forwardable list
   and refuses to include Intel-owned files.
   ```bash
   scripts/sync/list_pristine.py 9124d696 --triage /tmp/t.json
   # -> 339 candidates: PRISTINE 107, TOUCHED 229, INTEL-OWNED 3
   ```
3. **`scripts/sync/tripwire.sh`** — §6.3. Needs the Stage 0 baseline tag.

Next quarter's sync starts by re-running #1 with the new `since` hash. That is the whole
point: this quarter's 783-commit surprise becomes a 20-minute report.

---

## 8. Release & versioning

Fork keeps its own `1.0.x` line. Per `UPSTREAM_SYNC.md`, after the **final** wave update:
- `docs/UPSTREAM_SYNC.md` — *Last synced upstream commit* → `4528b56f`, era → `0.24.3`
- `IntelBuildInfo.swift` — `upstreamBase = "0.24.3"`, `upstreamCommit = "4528b56f"`
  (currently `"0.20.3"` / `"9124d696"`; the release script greps `upstreamBase`)

Intermediate waves ship with the **old** upstream metadata — the fork is not synced to 0.24.3
until Wave E lands. Do not stamp partial progress as a completed sync.

Release ceremony per wave (from `intel-plugin`/release memory):
`git stash push -- …/FoundationModelService.swift` → `scripts/release/cut_intel_release.sh
<version> "<notes>"` with the **sandbox disabled** → `git stash pop` → verify
`FoundationModelService` is in no commit.

⚠️ **Auto-update trap:** if any inflated-`CFBundleVersion` debug build (≥100) is sideloaded on
Rosy during testing, it MUST be replaced by a real release afterward or Sparkle silently
stops offering updates forever.

---

## 9. Effort estimate & sequencing

| Release | Wave | Volume | Mechanism | Effort | Gate before shipping |
|---|---|---:|---|---|---|
| — | 0 · Safety net | — | — | S | tree green at macOS 13 |
| **1.0.32** | A · Hotfixes | 7 commits | HP | M | Rosy: keychain + billed Router turn |
| **1.0.32** | B · Crashes/hangs | 11 commits | CP | M | Rosy: settings/sheets/find-bar/display |
| **1.0.33** | C · Pristine FF | 52 files (+compiler-expanded) | FF | **L** — biggest Ventura burden | tripwire + icon check on Rosy |
| **1.0.33** | E′ · Proxy & MCP | 7 commits | CP | S | MCP reconnect + proxy honored |
| **1.0.34** | D₀ · **Projects** | 6 sub-steps | HP (rebuild) | **XL** | instructions provably reach the model |
| **1.0.34** | D₁ · Chat QoL | ~15 headline | HP | L | per-feature smoke |

**Critical path:** Release 1 is independent and can start now. Release 2 must precede Release 3
(Projects builds on the modernized base). Within Release 3, D₀ before D₁ — Projects touches
`ChatView.swift` structurally, and doing the QoL polish first would mean doing it twice.

**Where the time actually goes:** not the commit count. Wave C's *Ventura backport* and Wave D₀'s
*rebuild-against-mirrors* dominate. A 7-commit wave (A) and a 52-file wave (C) can cost the same.

---

## 10. Backlog (deliberately deferred)

Recorded so these are decisions, not omissions.

| Item | Why deferred | Unblocked by |
|---|---|---|
| **`311d9095` storage encryption opt-in** (50 files) | Renée's call, 2026-09-02. Riskiest commit in the sync: touches SQLCipher on a fork that already has an unexplained `hmac` decrypt error in Rosy's logs. An encryption migration on top of an unexplained decrypt failure is how chat history dies. | Root-causing the Rosy `hmac` error. Then: own branch, full `~/.osaurus` backup first, alone. |
| **Wave F · deferred-shelf re-triage** (61 DEFER commits) | Most were "entangled" with things that Releases 1–3 will have landed or definitively ruled out. Re-triaging now would be re-work. | Release 3 shipping. Expect most to resolve to SKIP once the Orchestrator dependency is confirmed absent. |
| **Knowledge base on Intel** (incl. project knowledge collections) | **Wanted, not abandoned** (Renée, 2026-09-02). Previously written off as permanently amputated because it needs embeddings. That reasoning is obsolete: the fork's pure-Swift **model2vec / `potion-base-8M`** static embedder already runs acceptably on Rosy — the same one powering local semantic memory. So Knowledge is *viable* on Intel, it is simply not in this sync. | Its own arc after `1.0.34`. Intel Projects ships as instructions + memory + grouping (§4 Release 3); knowledge collections get wired in when the Knowledge subsystem itself is revived. |
| **Identity restore UI** | `OsaurusIdentity.restore(words:)` landed in Wave A, but the implementing agent correctly stayed out of `Views/`, so there is no `RecoverFromMnemonicSheet` and the feature is not reachable from the UI. Backend is ready and tested-by-compile. | A small view + an `IdentityView` entry point. Do it before advertising restore in any release notes. |
| **`69519a14` cloud image/video generation** | Marked PORT by first-pass triage, but likely depends on the amputated image-generation subsystem. **Unverified.** | Reading the commit before touching it. |
| **Router billing ledger is dead code** | Found 2026-09-02, not from any upstream commit: `RouterBillingLedger.record(...)` and `noteRouterSummary(...)` have **zero call sites**, and `CloudChatEngine` never references either — so `CreditsView` reads a table nothing writes. Every Router spend event is dropped, most likely by the SSE loop's `guard let choices = ... else { continue }`. **Deliberately not fixed in `1.0.32`:** the correct fix depends on the Router's actual summary-frame shape, which nobody has observed. Wave A's new `Non-delta SSE frame keys=…` diagnostic prints exactly that on the next real Router turn on Rosy. Guessing the shape now would be cargo-cult. | One billed Router completion on Rosy with `1.0.32` installed, then read Console.app. Fix lands in `1.0.33`. |
| **Two proxy readers now exist** | Fixing the plugin-repo download leak required a second, private proxy-config reader (`RepositoryGlobalProxySettings` in `Packages/OsaurusRepository/CentralRepositoryManager.swift`), because `OsaurusRepository` cannot import `OsaurusCore` — `OsaurusCore` already depends on it, so the import would cycle. Correct under the constraint, but **two readers can drift**: any change to how proxy config is stored or read must update both. | Extracting a tiny shared proxy-config module that both packages can depend on — the same shape upstream reached for with `Packages/OsaurusNetworking`. |
| **Provider discovery bypasses the global proxy** | `IntelStubConformers.swift` uses `URLSession.shared` 6× and `makeSession()` 0× — the 1.0.24 global-proxy batch never reached this file, so `/models` probes leak around a configured proxy. Pre-existing. | Wave E′ in Release 2 (`0ba6a01a` covers exactly this). |
---

## 11a. Open follow-ups (2026-09-04)

| Item | Note |
|---|---|
| **`OsaurusCoreTests` does not compile** | Pre-existing, not caused by any sync work. `Tests/Tool/ConfigurationDomainRegistryTests.swift` and `Tests/Context/PreflightCompanionsTests.swift` reference types gated out under `#if !OSAURUS_INTEL`; `Tests/Networking/GlobalProxyConfigurationTests.swift` references `StoragePathsTestLock` and `GlobalProxySettings.sharedSession()`, neither of which exist in this fork. So `swift test` cannot run at all on the main target — which is why every verification in this sync leaned on `swift build` plus targeted new test files instead. Worth fixing: a fork with an uncompilable test target has no regression net, and both bugs that shipped in 1.0.32 were the kind a test would have caught. |
| **`swift test --arch x86_64` cannot load the XCTest bundle** on the arm64 dev machine | Environment limitation, not a code issue. Tests must be run on the native arch; only non-test builds cross-compile cleanly. |
| **22 upstream commits still worth porting** | From a second sweep of the 174 PORT-verdict commits never revisited after the five prioritized clusters. Shortlist and landmines in `missed_wins.md` (scratch). Three of that sweep's picks turned out already-applied via Wave C's file fast-forwards — when filtering candidates, compare against `git diff upstream/main HEAD`, not against a list of ported commit hashes. |

---

## 11b. Post-release postmortem — 1.0.32 (2026-09-04)

Two failures on first install, both of the same shape: **a lookup that fails returns a
plausible empty value instead of an error**, so the UI shows "nothing here" and nobody
learns anything.

### All chat sessions vanished — our bug

`pinned: Bool = false` was added to `ChatSessionData`. **Swift's synthesized `Decodable`
does not fall back to a property's default value** — a missing key throws `keyNotFound` —
and `loadFromDisk()` decodes with `try?` and skips whatever fails. Every session written
before that field existed was silently dropped from the sidebar.

No data was lost: sessions are one JSON file each, and nothing in the load path deletes or
rewrites them. Fixed in `fbd569fe` with an explicit tolerant `init(from:)`.

> **Rule for this fork: never add a non-optional stored property to a persisted `Codable`
> type.** Give it a case in the hand-written `init(from:)` with `decodeIfPresent` and a
> default. A property default alone will not save you. The same audit cleared
> `ServerConfiguration.fontSizeMultiplier` (already tolerant) and `MCPProviderState` (not
> `Codable`), so `pinned` was the only instance — but the trap is permanent.

### Every provider reported 0 models — not a code regression

All three providers 401'd, with `request_bytes=106` proving no `Authorization` header was
sent at all. `RemoteProviderKeychain.getAPIKey` was **untouched by the sync**; what changed
was the binary, which is what the keychain ACL binds to. Because the query sets
`kSecUseAuthenticationUISkip`, macOS never prompts — the read just fails and returns `nil`,
indistinguishable from "no key saved". The dialog's "Stored in Keychain" is a static label,
not a live check.

**Remedy: re-save the API key in Settings → Providers.** Confirmed working. `69f1c443` now
logs any non-`errSecItemNotFound` status with its `OSStatus` and the remedy, so the next
occurrence is one Console line rather than a log-forensics session.

> **Watch item:** the stable signing identity is supposed to keep the keychain ACL across
> updates, and it held through 1.0.30 and 1.0.31. Why it did not hold at 1.0.32 is not
> established. If the next release also needs keys re-entered, check the installed app's
> authority with `codesign -dv --verbose=4 /Applications/osaurus.app` before assuming it is
> a one-time migration.

---

## 11. Known first-pass triage errors

The per-commit verdicts came from small models and are a map, not an authorization. Already
corrected: Product Hunt marketing dialogs (`f8b1c02e`, `67eeaf0b`) mislabelled PORT; the
swap-pressure banner series (`a9d2a150`, `29fedb38`, `1b58dcf9`) warns about local-model RAM
pressure and is meaningless cloud-only. Still unverified: `69519a14` ("cloud image and video
generation") is marked PORT but likely depends on the amputated image-generation subsystem —
**verify before touching it.**

Assume more errors exist. Every commit gets read before it lands.
