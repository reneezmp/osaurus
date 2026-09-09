# Deferred-commit feasibility audit — 2026-09-08

## Correction

The earlier ledgers used **DEFER** for several different judgments: hardware-incompatible, irrelevant to the Intel product, mixed with excluded code, large, or simply difficult. That blurred feasibility with effort. This audit supersedes every DEFER verdict in the 0.24.3 and 0.24.7 ledgers.

Of the 73 deferred commits, **58 are technically feasible Intel work**: 1 is now landed, 28 have a useful slice ready for direct porting, and 29 belong on an explicit dependency-ordered roadmap. The remaining 15 are skips because they only serve the removed MLX/local-model runtime, replace an intentionally different Intel subsystem, or add eval-only machinery rather than app behavior.

The live ledgers now show 72 DEFER rows because `eca456c3` was corrected to PORT in the same commit. The 73 count above refers to the pre-correction ledgers: 61 in the 0.24.3 ledger plus 12 in the later ledger.

“Touches excluded files” is no longer a blocker by itself. A future verdict must identify the incompatible behavior, or classify the commit as a hand port / roadmap item. Size and conflict are effort estimates.

| Commit | Corrected verdict | Upstream change | Why |
|---|---|---|---|
| `eca456c3` | **LANDED** | Add Claude Code CLI integration (#2257) | Core CLI discovery, auth UI, text streaming, model routing, and teardown now compile on Intel; optional MCP/agent mode remains additive. |
| `03ea4c93` | **PORT NEXT** | resolved crashes and hangs (#1575) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `f9b72fb5` | **PORT NEXT** | fixed app hangs (#1595) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `ad0698d7` | **PORT NEXT** | Stabilize the default configuration agent and fix disappearing custom agents (#1608) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `d1b96a5e` | **PORT NEXT** | Harden Bonjour discovery (security, reliability, discoverability) (#1658) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `4be5a577` | **PORT NEXT** | Cut per-turn prompt cost: remote prompt caching + local KV prefix reuse + measured text trims (#1798) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `4ff27e51` | **PORT NEXT** | fixed capabilities toggle initial render (#1878) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `a9ae5fd9` | **PORT NEXT** | Free model memory on chat close, respond to memory pressure, and cap unbounded caches (#1901) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `2b15a507` | **PORT NEXT** | Repin vmlx to 0d3444ca (gemma4 parser fix #128) + fix reasoning-toggle default display (#1950) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `b621603f` | **PORT NEXT** | Checkpoint: stop the gemma tool-loop, two crashes, and lying tok/s (#2015) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `3ddc5215` | **PORT NEXT** | fixed main thread hangs across launch, storage, tts, and streaming (#2030) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `61dad2f3` | **PORT NEXT** | Reduce redundant agent prompt context (#2051) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `d8962622` | **PORT NEXT** | Fix skill discovery metadata loss and MCP capability-load reliability seams (#2089) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `03fad56f` | **PORT NEXT** | fixed app hangs (#2095) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `846ca918` | **PORT NEXT** | Preserve explicit Thinking mode across agent tool turns (#2101) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `9b0331fd` | **PORT NEXT** | fix: honor reasoning toggle across agent tool loops (#2105) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `4daee7b3` | **PORT NEXT** | fixed app hangs (#2128) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `450690b4` | **PORT NEXT** | group consecutive thinking and tool activity into one expandable row (#2142) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `23e2b570` | **PORT NEXT** | Eliminate app hangs: unblock MainActor, bounded cancellation, killable plugin host (#2239) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `03557065` | **PORT NEXT** | Harden capability readiness and authorization (#2258) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `5d16b603` | **PORT NEXT** | Clarify capability IDs and recover grouped tool calls (#2309) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `06af55e7` | **PORT NEXT** | Bound capability group-load schemas + repin vmlx (Muse Glimmer runtime) (#2336) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `90b86b81` | **PORT NEXT** | fit fixed size sheets to the screen so action footers stay reachable (#2435) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `64bc6580` | **PORT NEXT** | Sampling Defaults were inert on almost every model, and nothing showed what actually ran (#2442) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `1f052d17` | **PORT NEXT** | Show and cancel exact live inference work (#2563) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `34a64dc2` | **PORT NEXT** | fix /api/show for external models and report tool/thinking capabilities (#2606) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `54aa52ad` | **PORT NEXT** | Chat: queued steer ordering, stale notices across the steer boundary, empty wrap-up bubble (#2653) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `e00a9d88` | **PORT NEXT** | Research completion: announce-only recovery names what the model can do; promised-work endings recovered; replayed retrieval failures escalate before stopping; window-close crash fixed (#2656) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `7e109ade` | **PORT NEXT** | Chat: a run cancelled during its cold load must not roll back the retry that already owns the session (#2668) | Touches a live Intel path and has a narrow useful subset that can be adapted without waiting for another milestone. |
| `64e524f6` | **ROADMAP** | updated onboarding flow (#1649) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `67fba746` | **ROADMAP** | harden remote agent security and reliability (#1623) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `f7e683df` | **ROADMAP** | Fix and harden remote agent (Mode 2) runs (#1636) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `3bdbebd9` | **ROADMAP** | added file diff cards for folder and sandbox edits (#1683) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `6facd2bc` | **ROADMAP** | Unify sub-agent delegation under one registry + per-agent Sub-agents tab (#1731) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `85fafd3f` | **ROADMAP** | Split spawn into spawn_agent + spawn_model with cross-model residency (#1750) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `5856d350` | **ROADMAP** | Standardize on "subagent" spelling (drop hyphenated "sub-agent") (#1769) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `4b4aa10f` | **ROADMAP** | Settings IA cleanup: grouped sidebar, relocations, unified card primitives (#1792) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `afa32e5c` | **ROADMAP** | Unify runtime policy and bounded subagent delegation (#2165) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `44548e90` | **ROADMAP** | Native channel presence, formatting, and reactions (#2202) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `2ecf2b05` | **ROADMAP** | Make the Mac harness leaner and more reliable (#2250) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `e7c4f22f` | **ROADMAP** | add follow up question suggestions after a turn (#2384) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `556d0189` | **ROADMAP** | let agents write knowledge directly with call-time approval (#2480) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `f0e5a1be` | **ROADMAP** | Redesign onboarding as a 3-screen (#2481) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `8d7c3dd4` | **ROADMAP** | Default-agent declarative config + delegation orchestrator (#2485) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `7aa8d7a3` | **ROADMAP** | Introduce the Orchestrator: dedicated settings tab, identity, and launch polish (#2493) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `679ba750` | **ROADMAP** | Orchestrator-first delegation: default-on spawn pool, same-turn spawn activation, and delegated artifact pass-through (#2498) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `8aa97c06` | **ROADMAP** | Onboarding polish: motion system, Figma speech bubble, click-through fixes; Top Picks to Ornith 1.5 (#2503) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `5523962d` | **ROADMAP** | revamped settings (#2517) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `c853ca4c` | **ROADMAP** | Spawn admission: price a child by its bounded request, not the retention cap (#2533) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `e03127e7` | **ROADMAP** | Watcher/dispatch agents can actually reach their target folder (#2603) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `970ae921` | **ROADMAP** | added clickable knowledge document links in chat (#2610) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `5a92cbc4` | **ROADMAP** | added project folder support (#2611) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `b285b946` | **ROADMAP** | Watcher dispatch grounds itself; config apply says DONE (#2628) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `ae942a15` | **ROADMAP** | browser style chat tabs with agents sidebar and history dialog (#2630) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `c7f46727` | **ROADMAP** | Folder and knowledge listings: paged file_search/list_knowledge with totals, truncated-tree prompt line, ungrounded-claim advisory (#2646) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `88075278` | **ROADMAP** | fix history dialog row actions and keep the dialog open under nested alerts (#2661) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `81cea6be` | **ROADMAP** | added agent filter dropdown to the history dialog (#2662) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `75c1fd39` | **ROADMAP** | open chat windows full size and start the layout tour after first run dialogs (#2664) | Technically feasible on Intel, but should land with its named feature or prerequisite so it is coherent and testable. |
| `bae6c937` | **SKIP** | improved tool calls and prefill speed for small local models (#1577) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `285d6b62` | **SKIP** | agent db upgrade (#1640) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `135fcea4` | **SKIP** | Add tool result grounding evals (#1740) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `343482c4` | **SKIP** | Upgrade evals harness: repeat/resume runs, judge audit + calibration, micro-perf and prompt-injection suites (#1789) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `62e3aee2` | **SKIP** | Model catalog IA cleanup: family-grouped cards, variant picker, chat-only org fetch (#1800) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `f6787f35` | **SKIP** | Eval matrix chat-model/subsystem split, delegation cases, and outcome-based frontier rubrics (#1853) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `1b2a5c79` | **SKIP** | speed up onboarding model downloads via authenticated proxy (#1965) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `55ffd834` | **SKIP** | Pin DSV4 disk-prefix fix and improve eval proof (#2264) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `d1d71402` | **SKIP** | Report why the disk cache was disabled instead of silently downgrading (#2273) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `319b7c71` | **SKIP** | Fix first-turn double prefill (warmup cache-salt mismatch), warmup tool-scope kill, cache-size settings hazards; repin vmlx (#2331) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `b7f86935` | **SKIP** | Disk cache: auto-size to 10% of disk, surface usage in chat, add Clear SSD Cache (#2436) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `a2e781be` | **SKIP** | Disk cache size is a percent in Settings, and every stale GB reader is fixed (#2441) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `dbe6a508` | **SKIP** | fix wasted warm ups and the jumping context tooltip on channel bound agents (#2468) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `ca2f8b73` | **SKIP** | Use Raptor for mainstream onboarding defaults (#2574) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |
| `62664a08` | **SKIP** | added raptor v0.5 in what's new modal (#2577) | Specific to the removed MLX/local-model runtime, an unused storage/runtime replacement, or eval-only machinery with no Intel product behavior. |

## Execution order

1. Finish and validate the Claude Code CLI slice (`eca456c3`).
2. Re-review the 28 **PORT NEXT** commits by live Intel file overlap; extract narrow patches and tests rather than replaying whole commits.
3. **Completed 2026-09-08:** project working folders and Knowledge now ship together with the full project page; folder roots are per-chat and also drive Claude Code's working directory.
4. Revisit shell/history, delegation/orchestrator, channels, and onboarding as explicit product milestones.

The **SKIP** label means “no useful behavior in this fork,” not “too hard.” If the Intel product later adopts that subsystem, its commits return to the roadmap.
