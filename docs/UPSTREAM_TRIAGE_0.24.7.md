# Upstream triage: 0.24.3 → 0.24.7

**Range:** `490e0a58..7e109ade` (inclusive) — 53 commits

This ledger is the final Intel verdict for the upstream 0.24.4–0.24.7 window.
It consolidates the three bounded reviews and supersedes their provisional
`REVIEW` labels. It is a hand-port map, not a cherry-pick queue.

## Method

Every commit was first intersected with the `exclude:` lists in
`Packages/OsaurusCore/Package.swift`, then read against the live Intel
architecture. A path on disk is not evidence of a feature: it must be outside
the source-target exclusions and have a live caller. The target excludes the
local vMLX runtime, model manager, Foundation-model service, agent-loop and
prompt-composer stack, tool registry/capability tools, sandbox and most
remote-agent plumbing. The test target separately excludes suites for those
amputated contracts.

Final counts: **7 PORT**, **2 PARTIAL**, **12 DEFER**, **32 SKIP**.
`PARTIAL` means the useful self-contained Intel behavior landed while coupled
upstream lifecycle/runtime changes did not.

| Upstream | Final | Live Intel adaptation / rationale |
|---|---|---|
| `490e0a58` | PORT | FDA system-TCC sentinel/read-byte ported with `497fa2fb`. |
| `34a64dc2` | DEFER | External-model capability report needs an Intel cloud contract first. |
| `be4c0577` | SKIP | vMLX repin; local runtime is excluded. |
| `a186dd06` | SKIP | Upstream appcast is not the Intel release feed. |
| `970ae921` | DEFER | Knowledge links wait for the local-first Knowledge milestone. |
| `5a92cbc4` | DEFER | Project folders require per-chat folder state; Intel's current global folder context would leak one chat's selection into another. |
| `6322c370` | PARTIAL | CLI AppControl cold-start/duplicate-window fix ported; unrelated AppDelegate lifecycle differs. |
| `88b4efd1` | SKIP | vMLX repin; no compiled Intel target. |
| `b8be7f52` | PORT | Sidebar and agent-cycle shortcuts bind the compiled Intel window state and command routing. |
| `497fa2fb` | PORT | FDA SQLite-header validation ported with `490e0a58`. |
| `7196eb41` | SKIP | Upstream appcast metadata. |
| `e85a2931` | SKIP | MTP controls require excluded local runtime. |
| `aa4d4053` | SKIP | MTP activity requires excluded generation events/runtime. |
| `97f5cc19` | PARTIAL | UTF-8 TokenEstimator and nonisolated tool-config drain ported; coupled local/runtime fixes remain excluded. |
| `0520691a` | SKIP | Capability manifest/gateway is excluded. |
| `9d7d0712` | SKIP | Upstream web pipeline is an excluded/new subsystem. |
| `dbd97117` | SKIP | Upstream appcast metadata. |
| `0e4daaaa` | SKIP | Upstream release-note metadata. |
| `a5d65e88` | SKIP | vMLX proposal-head pin. |
| `1b8ae239` | SKIP | Agent-loop/tool-registry feature is excluded. |
| `b285b946` | DEFER | Watcher/config grounding needs a coherent Intel folder execution design. |
| `52f93e49` | PORT | Cmd-N and toolbar New Chat retain the open/current Intel project and its valid default agent. |
| `900eefe9` | SKIP | Local-model delegation residency system is absent. |
| `a3c00d22` | SKIP | MTP/vMLX stream-tail and bundle advisory are local-runtime work. |
| `c6737abd` | SKIP | Agent-loop/sandbox grounding; UI fragments would be misleading alone. |
| `7cd8c0ae` | SKIP | Follow-up to absent `AgentTaskState`. |
| `cfa7e3ea` | SKIP | `ModelManager` is excluded. |
| `8f67a9f1` | SKIP | Local reasoning detector and agent loop are excluded. |
| `6f760a9d` | SKIP | vMLX repin/runtime metadata. |
| `0a17c866` | SKIP | Upstream appcast metadata. |
| `69e19e06` | SKIP | Watcher host-folder dispatch depends on excluded sandbox/tool routing. |
| `d96d20be` | SKIP | Repetition window changes excluded local `ModelRuntime`. |
| `75c20699` | SKIP | Session tool scope depends on excluded loop/composer/registry. |
| `7b6d05cb` | SKIP | Skill mutation requires excluded tool registry/capability gateway. |
| `098cbd4e` | PORT | Claude `data_files` indexes now name batch ZIPs and are quiet beside successful batch imports. |
| `ae942a15` | DEFER | Large tabs/history chat-shell redesign conflicts with Intel Projects and toolbar structure. |
| `54aa52ad` | DEFER | Queued-steer fix needs Intel CloudChatEngine ownership tracing. |
| `c7f46727` | DEFER | Folder/Knowledge paging belongs to the planned Knowledge milestone. |
| `605f862a` | SKIP | Tool-flow/manual-mode stack is excluded. |
| `3e5a6e16` | SKIP | vMLX repin. |
| `e00a9d88` | DEFER | Research recovery depends on deferred chat shell and excluded agent-loop state. |
| `9af6f53d` | PORT | Intel resolves metadata-only rows through its durable session manager before loading and saving. |
| `4c9bbdd3` | SKIP | Incomplete-work finalization is agent-loop/local-model infrastructure. |
| `8af0a985` | PORT | Folder chip accessibility name, value and identifier ported on the live composer chip. |
| `88075278` | DEFER | Nested-alert repair has no live history-dialog caller until the shell port. |
| `81cea6be` | DEFER | Agent filter belongs to deferred history dialog. |
| `a4eb0bb4` | SKIP | Lazy local-model loading is excluded cloud-incompatible runtime work. |
| `32a7fc57` | SKIP | Follow-up to excluded lazy local loading. |
| `75c1fd39` | DEFER | Window sizing/tour must be reconciled with Intel toolbar and future shell. |
| `835ee1fe` | SKIP | OpenCode affinity changes excluded remote-provider service. |
| `d2510a08` | SKIP | `update_skill` dispatch requires excluded skill/tool plumbing. |
| `c4a62c55` | SKIP | Swap-pressure UI would falsely imply local model residency. |
| `7e109ade` | DEFER | Re-triage stale retry ownership against CloudChatEngine before a narrow run-ID guard. |

## Port guardrails

- Hand-port only: this fork's history shows that clean upstream cherry-picks
  import excluded architecture.
- Keep macOS 13 compatibility: no macOS 14-only API or two-parameter
  `onChange`; use already-proven SF Symbols.
- Persisted Codable types may gain only tolerant optional-compatible decoding;
  never add a non-optional stored property without a migration strategy.
- `FoundationModelService.swift` remains out of scope.
- Project-folder support stays deferred until folder context is scoped per chat;
  the project-aware navigation and shortcut behavior is complete and compiled.
