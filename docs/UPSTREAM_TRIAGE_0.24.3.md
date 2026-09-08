# Upstream 0.20.3 → 0.24.3 — Intel fork triage ledger

> **2026-09-08 correction:** The historical `DEFER` label below conflated difficulty, mixed commits, and actual incompatibility. [The full feasibility audit](DEFER_FEASIBILITY_AUDIT_2026-09-08.md) supersedes those verdicts: 58/73 are feasible Intel work; 15 are true skips.


Range: `9124d696..4528b56f` (783 commits). 307 auto-eliminated (docs/CI/appcast/i18n/evals, vmlx repins + Package.resolved churn, amputated-subsystem-only, brand-new upstream subsystems). 476 reviewed below.

# Window 1

| sha | what it does | verdict | reason |
|---|---|---|---|
| b8ef10aa | added ability to disable osaurus router | PORT | Router is core cloud infrastructure in fork; relevant disable toggle |
| be263b1e | Add MCP Server Hub | PORT | MCP is active subsystem in fork; server hub integration needed |
| bd50e2be | fixed issue with agent deletion | PORT | Basic agent management fix; core agent UI stability |
| 03ea4c93 | resolved crashes and hangs | DEFER | MetalGate (MLX, amputated) + potential macOS SDK API calls need review |
| bae6c937 | improved tool calls and prefill speed for small local models | DEFER | Local model optimization; fork mirrors ModelMetadataParser but doesn't use local inference—needs verification |
| 9c41d3a8 | disable settings save buttons until there are unsaved changes | PORT | Pure UX improvement; not tied to amputated subsystems |
| b70abcc5 | Add theme library management center | PORT | Themes are active; new feature in live subsystem |
| ef888fd3 | Add agent loop eval regression lab | SKIP | OsaurusEvals harness is amputated |
| 87cd810f | Add memory management console | PORT | Memory is cloud-managed; relevant to fork's infrastructure |
| 65b17a37 | Add tool exposure control center | PORT | Tool management for MCP/cloud tools is active |
| ccbd9252 | New Feature: Computer Use Subagent | SKIP | Computer Use explicitly amputated; 109 files including amputated evals |
| 614fbf8b | Add OpenAI-compatible FIM request handling | PORT | Networking/API compatibility fix; relevant to cloud inference |
| e6e5ee93 | Add sandbox provisioning diagnostics | SKIP | Sandbox is amputated |
| f9b72fb5 | fixed app hangs | DEFER | ModelDownloadView (amputated) mixed with active components; needs review |
| f0e8953c | updated chinese translations | SKIP | SandboxView (amputated) is primary file; skip this batch |
| 8a145f36 | decouple sandbox tools from the agent Tools toggle and compact sandbox prompt sections | SKIP | Sandbox is amputated |
| c654abc1 | Laguna-M.1 + VibeThinker-3B serving: fix Laguna chat garbage (missing-BOS) + drop rep-penalty special-case | PORT | Model family configuration; relevant to cloud model setup |
| ad5a2c5f | fix app hang render path | PORT | Theme + system monitor stability fix; general robustness |
| c7a07ecc | UI polish after fixes | PORT | Memory/tool views UX improvement in active subsystems |
| 311d9095 | Make at-rest storage encryption opt-in (plaintext by default, FileVault-gated migration) | PORT | Fundamental storage architecture; important for data integrity |
| a8802dc2 | improved evals framework | SKIP | OsaurusEvals harness is amputated |
| 1fcd70e4 | fixed issue with relay not showing errors | PORT | HTTPHandler fix for relay error reporting; networking stability |
| d365216b | evals: optimization loop backbone + W1-W6 harness and local-quality fixes | SKIP | Skill (amputated) + OsaurusEvals harness (amputated) |
| 4002b7c0 | Add local model compatibility preflight | SKIP | Local model loading is amputated |
| 71215678 | Add Provider Connectivity Center | PORT | Remote provider management is active |
| dd35736a | updated chinese translations | SKIP | Mix includes SandboxView (amputated) and VoiceView (amputated) |
| ad0698d7 | Stabilize the default configuration agent and fix disappearing custom agents | DEFER | Agent config stabilization + evals entanglement; needs careful review |
| 129e3772 | fixed main thread hangs | PORT | ModelDetailView fix; general stability improvement |
| f5e2ff97 | Add opt-in frozen screen context for chat (Computer Use) | SKIP | Computer Use is amputated |
| 3695ef70 | Make the Default agent configuration-only in chat | PORT | Agent configuration UX management |
| 9ddb49b0 | added additional migration hardening | PORT | Storage migration stability; important for data integrity |
| 2de2f4fb | gemma 4 12b optimization loop | SKIP | OsaurusEvals harness is amputated |
| 1cbc9a9d | updated themes view design | PORT | Themes subsystem is active |
| 3b458e00 | improved screen context evals | SKIP | OsaurusEvals harness is amputated |
| 67fba746 | harden remote agent security and reliability | DEFER | Remote agent subsystem is amputated; HTTP handler hardening may be separate |
| 9ac07e14 | add lossless tool-output compressor, per-task context-token telemetry, and real remote completion tokens | SKIP | OsaurusEvals harness is amputated |
| ae3a3c5d | updated computer use docs | SKIP | Computer Use is amputated |
| 304ad2bb | Add shared global proxy controls | PORT | Proxy configuration for networking is relevant |
| 020879fb | Add schedule automation history | PORT | Scheduling subsystem is active |
| 21310bab | Add permission-gated screenshot slash command | PORT | System permission and screenshot feature is relevant |
| 24a30437 | Add Agent Channels with Discord connection | SKIP | Agent Channels is explicitly amputated |
| dc5ba358 | improved remote agent ux | SKIP | RemoteAgent/RelayTunnel subsystem is amputated |
| fd6b4947 | fix /memory/ingest distillation and harden launch crashes | PORT | Cloud memory management is active |
| f7e683df | Fix and harden remote agent (Mode 2) runs | DEFER | Remote agent is amputated; need to check if HTTPHandler fix is general |
| 8a5606d0 | updated chinese translations | PORT | Translation-only change; always port translations |
| 480e10b5 | qol improvements | PORT | General UX improvements across active subsystems |
| d264b231 | make plain-text answers the primary agent-loop exit | PORT | Agent prompt tuning; relevant to cloud agent behavior |
| 581f164d | fixed app hangs | PORT | BackgroundTaskManager + NotchView stability fixes |
| 285d6b62 | agent db upgrade | DEFER | Agent database schema upgrade needs careful review; may relate to amputated agent infrastructure |
| ec725066 | Add Agent Channel Connection Center | SKIP | Agent Channels is amputated |
| cafc7055 | show pasted content preview in chat | PORT | Chat UX improvement in active subsystem |
| 64e524f6 | updated onboarding flow | DEFER | Onboarding often references all features; needs review to skip amputated ones |
| 895b05fe | unify local and remote agent detail views | SKIP | RemoteAgent subsystem is amputated |
| d1b96a5e | Harden Bonjour discovery (security, reliability, discoverability) | DEFER | Bonjour use case unclear; may be for local inference (amputated) or remote agents (amputated) |
| 2d0da4e4 | Polish remote agent connect UX | SKIP | RemoteAgent/RelayTunnel subsystem is amputated |
| 8a582aae | updated chinese translations | SKIP | Mix includes ModelDownloadView (amputated) and VoiceView (amputated) |
| f67c3a3e | QoL improvements | PORT | General UX improvements across management/chat views |
| 1fd695a6 | fixed app hangs | PORT | FolderContextService + ExecutionContext stability fix |
| 661eaeac | Surface host-side remote-agent (p2p) activity | SKIP | RemoteAgent activity logging is amputated |
| 3a83cf31 | persist per tool disable state for MCP provider tools | PORT | MCP tool state management is active |
| 767abeb4 | make agent run honor agent temperature | PORT | Agent parameter handling; relevant to cloud agent config |
| c401e332 | Add Computer Use regression scorecards | SKIP | Computer Use (amputated) + OsaurusEvals (amputated) |
| c05947f0 | Fix #1680: surface (not silently truncate) multi-step tool tasks on a premature-EOS empty turn | PORT | HTTPHandler networking/tool fix for cloud inference |
| a29fe877 | Native image generation/editing + agent delegation (spawn / local_delegate) | SKIP | Image generation (amputated) + MetalGate (amputated) |
| cc6732d7 | fix context budget popover crash on System Prompt drill-down | PORT | FloatingInputCard UI crash fix |
| 3bdbebd9 | added file diff cards for folder and sandbox edits | DEFER | Sandbox is amputated; folder diffs might be relevant but needs untangling |
| 4a4b3bd7 | improved plugin discovery for smaller local models | SKIP | Local model optimization is amputated |
| 161e6ca5 | fix app hang watchdog stalls across folder, tool listing, permissions, and launch | PORT | FolderContextService + SystemPermissionService stability fix |
| b76f887e | improved settings ux | PORT | Settings UI improvement across active subsystems |
| 62f5fa41 | fix: use veryShortWeekdaySymbols for schedule weekday display | PORT | Schedule display localization fix |
| 5ca64d62 | updated chinese translations | PORT | Translation-only change; always port |
| 2d238592 | Fix same-turn capability tool activation | PORT | Chat interaction fix in active subsystem |
| 86195e1d | fixed tools page layout hang | PORT | ToolsManagerView (MCP) stability fix |
| 2e3af710 | hide non-MLX models that local engine can't load | SKIP | MLX filtering is for amputated local inference |
| 7b4e7785 | fixed app hangs | PORT | ChatView stability fix |
| 6facd2bc | Unify sub-agent delegation under one registry + per-agent Sub-agents tab | DEFER | Large 124-file refactor of agent system; evals entanglement needs careful review |
| 2c9d27b0 | Don't treat a bare `tools uninstall` name as a CWD path (avoid deleting the wrong directory) | PORT | CLI safety fix; prevents accidental directory deletion |
| f35fe751 | Fix MCP schema proxy miscasting JSON integers 0 and 1 as booleans | PORT | MCP/CLI compatibility fix |
| daacdebd | Tolerate and reap corrupt coordinator lock files | PORT | CLI coordinator robustness fix |
| 6d554ef8 | Accept an omitted args in desktop-format MCP bundle manifests | PORT | MCP bundle parsing compatibility |
| a78e4125 | Add `osaurus serve --supervise` keep-alive loop to survive app quit | PORT | CLI server supervision feature; relevant to daemon operation |
| bb60c267 | Avoid CLI crash on out-of-Int64-range model_info numbers in `show` | PORT | CLI robustness fix; prevents crash on large numbers |
| 6deeae93 | Promote Image Generation to its own Settings section | SKIP | Image generation subsystem is amputated |
| cfc0b4c0 | Unify all subagent flows through the eval host and benchmark local vs frontier | SKIP | OsaurusEvals harness is amputated |
| 2a2a06e8 | Add a standard per-agent model picker for chat-driven sub-agents | PORT | Agent model configuration is relevant |
| bdaea6af | Expand and optimize the OsaurusEvals catalog + harness (local vs frontier) | SKIP | OsaurusEvals harness is amputated (138 files) |
| 43f1e3a0 | Add router account usage center | PORT | Router billing/usage tracking for cloud infrastructure |
| 39b41e4c | Add redacted provider request diagnostics | PORT | Provider debugging/diagnostics for remote providers |
| c76a81a2 | fixed sentry hangs | PORT | SlashCommandStore stability fix |
| c0303e12 | reduced default agent prefill cost on small local models | SKIP | Local model optimization (amputated) + OsaurusEvals (amputated) |
| 85fafd3f | Split spawn into spawn_agent + spawn_model with cross-model residency | DEFER | Large 100-file agent system refactoring; evals entanglement and macOS SDK compatibility need review |
| 10791fd5 | minor image generation ux improvements | SKIP | Image generation subsystem is amputated |
| 18367d94 | fixed main thread freezes | PORT | ChatView + NativeMessageCellView stability fix |
| 8f80b11b | Coalesce subagent image progress in place; show step/ETA + elapsed | SKIP | Subagent image generation is amputated |
| 81d201c4 | Make built-in Default agent non-configurable; fix sub-agent toggle persistence | PORT | Agent configuration fix; relevant to cloud agent setup |
| 3bee1703 | Fix native image generation echoing artifact JSON instead of confirming | SKIP | Image generation subsystem is amputated |

# Window 2

| sha | what it does | verdict | reason |
|-----|-------------|---------|--------|
| f09b2123 | Rename Image Generation tab to Images | SKIP | Agent subsystem + ModelDownload amputated |
| 7b4ee592 | Fix KV-cache prefill reset after capabilities_load | SKIP | Local model inference amputated |
| 36e31641 | Make screen context per-agent Computer Use option | SKIP | Agent subsystem amputated |
| fb6e686a | Make local↔image model handoffs crash-free | SKIP | Local GPU inference amputated |
| 20fe3552 | Make Osaurus Cloud available by default | PORT | Cloud provider default applies to CloudChatEngine |
| 630ea9be | Cap tool rows in remote/plugin cards | SKIP | Plugin subsystem amputated |
| 5856d350 | Standardize "subagent" spelling | DEFER | Large refactor entangled with Agent system |
| c0b95c08 | Unify model-download tabs on ModelListRow | SKIP | ModelDownload + Voice subsystems amputated |
| 94921b45 | Minor UI tweaks | SKIP | Agent subsystem amputated |
| dfd412f6 | Fixed app hang sentry issues | PORT | General app stability fixes apply to fork |
| 6d9e0029 | Add AppleScript Computer Use subagent | SKIP | Agent subsystem amputated |
| d12cbb93 | Added Mistral provider support | PORT | Remote provider integration essential |
| 72c0f9e1 | Add model tool-use diagnostics | PORT | Applies to cloud provider diagnostics |
| 135fcea4 | Add tool result grounding evals | DEFER | Evals infrastructure, not critical runtime |
| adfc50a1 | Add Computer Use web form proof lane | SKIP | Agent/Computer Use amputated |
| 7eb5461f | Updated chinese translations | SKIP | Skills subsystem amputated |
| 343482c4 | Upgrade evals harness | DEFER | Testing infrastructure, not critical |
| f6b9c984 | Triage and fix sentry app hangs | PORT | General app infrastructure fixes |
| 50c2fb70 | Add Russian localization | PORT | Localization support, harmless |
| 4b4aa10f | Settings IA cleanup: grouped sidebar | DEFER | Large refactor entangled with Agent |
| f3d77609 | Generation params: seed, stop, penalties | PORT | Remote provider protocol improvements |
| c7c3f92c | Subagent harness hardening | SKIP | Agent subsystem amputated |
| 4be5a577 | Cut per-turn prompt cost: remote caching | DEFER | Mixed cloud/local features, need porting |
| 62e3aee2 | Model catalog IA cleanup | DEFER | Mixed amputated/active components |
| 978cca80 | Gate Rampart PII scan as GPU producer | SKIP | Local GPU inference amputated |
| c7978867 | Fixed Mistral reasoning format | PORT | Remote provider fix |
| 3d680ba0 | Onboarding model step resource costs | PORT | Cloud model onboarding improvements |
| 951e9b29 | Korean localization | SKIP | Agent/Sandbox/Skills amputated |
| 1551d302 | Stopped image composer chips wrapping | PORT | Chat input UI improvement |
| 2365e126 | Added favourite tab in model selector | PORT | Model picker enhancement, compatible |
| 938cf5b8 | AppleScript subagent upgrade | SKIP | Agent subsystem amputated |
| 2904fbe7 | Added transcription cleanup toggle | SKIP | Voice/TTS/Speech subsystem amputated |
| 79171ecb | Local-model harness fixes gemma-4-12B | SKIP | Local model optimization amputated |
| 84131694 | Polish Slack/Telegram Agent Channels | SKIP | Agent subsystem amputated |
| 0f684546 | Harden Slack/Telegram Agent Channels | SKIP | Agent subsystem amputated |
| 7cf02d4c | Fix task progress overlay menu bar | PORT | UI improvement for notification overlay |
| 22c7e78c | Redesign Agent Channels as Channels tab | SKIP | Agent subsystem amputated |
| 700ea0ba | Local-model harness fixes gemma-4-E4B | SKIP | Local model optimization amputated |
| 3172aae2 | Persist user turns before chat streaming | PORT | Chat streaming UX improvement |
| 0e520322 | Handle empty voice transcriptions | SKIP | Voice subsystem amputated |
| 4d43da85 | Start Sparkle update checks at launch | PORT | Update mechanism applies to fork |
| f6787f35 | Eval matrix chat-model/subsystem split | DEFER | Testing infrastructure, not critical |
| df969d9b | Fix self-scheduled runs not auto-starting | SKIP | Agent subsystem amputated |
| f24b8ab1 | Updated chinese translations | SKIP | Voice subsystem amputated |
| 8f9546ea | Discover custom external model folders | SKIP | Local model subsystem amputated |
| 79cc7dfe | Clarify memory ingestion diagnostics | PORT | Memory diagnostics apply to cloud |
| 907b19d7 | Cap sandbox plugin tool expansion | SKIP | Plugin subsystem amputated |
| c2523dff | Polish model catalog cards | SKIP | ModelDownload feature amputated |
| 27c6bf4c | Fix ExternalPlugin shutdown race | SKIP | Plugin subsystem amputated |
| ec2e4587 | Fixed sentry hangs | PORT | Chat UI fixes for active views |
| 774aa836 | Harden MCP surfaces: recovery, OAuth | PORT | MCP hardening essential for tools |
| 55c67634 | Agent DB: sandbox paths, db_export | SKIP | Agent subsystem amputated |
| 5ca01d42 | Added option to expand thinking | PORT | Reasoning display in chat UI |
| 02561780 | Fixed notch overlay menu bar placement | PORT | UI overlay bug fix |
| 4ff27e51 | Fixed capabilities toggle initial render | DEFER | Check if capabilities used in fork |
| 40031d8e | Fixed image attachments blocked/dropped | PORT | Chat attachment bug fix |
| 389a816e | Fixed plugin search matching | SKIP | Plugin subsystem amputated |
| 5ada76dc | Added full text chat search + Cmd+F | PORT | Chat feature enhancement essential |
| 3aec37b3 | Added terminal style input history | PORT | Chat input improvement |
| 993c2b49 | Improved favorite models UI | PORT | Model picker enhancement |
| 5a385f06 | Added per-model API exposure controls | PORT | Server settings for remote providers |
| a7fc168d | Proactive model warm-up KV caching | SKIP | Local model inference amputated |
| 435426db | Show live tool-call progress card | PORT | Chat UI improvement for tools |
| 0d07b052 | Fix Sentry: notch hangs, TextKit crash | PORT | Chat text rendering fixes |
| a9ae5fd9 | Free model memory on close | DEFER | Mixed local/cloud, need porting |
| 6d60a2c0 | Reflect tool-call failure in title | PORT | Chat UI improvement |
| 99ce8bd5 | Fix folder file-write bugs | PORT | Workspace bug fix |
| 8037848d | Improved chat thread performance | PORT | Chat rendering performance |
| 3776d116 | Add RAM tight-fit send gate | SKIP | Local model memory management |
| 7fe89812 | Improved RAM tight fit banner UI | SKIP | Local model feature amputated |
| 4bfc9bb8 | Fixed sentry hangs & crashes | PORT | App stability improvements |
| 926116b1 | Added RAM banner dismiss button | SKIP | Local model feature amputated |
| 112da6c8 | Update Simplified/Traditional Chinese | SKIP | Agent subsystem amputated |
| 8024c045 | Chat UI polish | PORT | Chat/model picker UI polish |
| 6bb79d30 | Add osaurus bench CLI | SKIP | Local inference benchmarking |
| 0fedf32f | Add provider connectivity triage | PORT | Remote provider diagnostics |
| 1915feae | Polish release UX details | PORT | Release UX improvements |
| 9c497e2a | Speed up HuggingFace downloads | SKIP | ModelDownload feature amputated |
| 09096b78 | Onboarding: recommend Ornith MXFP8 | SKIP | Local model onboarding amputated |
| 18bfc856 | Added timestamps to message cells | PORT | Chat UI enhancement |
| 70346b6f | Native web search: providers + Search tab | SKIP | Plugin/Agent subsystems amputated |
| 04bb4b7a | Fix RAM banner false positives | SKIP | Local model monitoring amputated |
| d5aea7fd | Decouple startup from plugin loading | SKIP | Plugin subsystem amputated |
| 57900df5 | Harden plugin repo refresh diagnostics | SKIP | Plugin subsystem amputated |
| f5e249d3 | Support installing plugin directories | SKIP | Plugin subsystem amputated |
| 973c771f | Fixed main thread hangs | PORT | App stability improvements |
| 063ac5fd | Added bulk plugin update option | SKIP | Plugin subsystem amputated |
| 2b15a507 | Repin vmlx + fix reasoning toggle | DEFER | Mixed local/cloud reasoning features |
| 31dd9f26 | Fix ChatGPT test-button, add grok-4.5 | PORT | Provider fixes + catalog update |
| 23705065 | Added in-app github token for plugins | SKIP | Plugin subsystem amputated |
| d358df15 | Added toggle for notch placement | PORT | UI overlay enhancement |
| 6c6f03fe | Credits UI: composer wallet, refresh | PORT | Credits/Router UI improvement |
| 4be798d8 | Flush pending stream text | PORT | HTTP streaming improvement |
| 5f12d260 | Remote provider hardening: all fixes | PORT | Critical remote provider stability |
| 1b2a5c79 | Speed up onboarding via proxy | DEFER | Check build script macOS compatibility |
| a15efa73 | Size model fit against GPU working set | SKIP | Local model memory management |

# Window 3

| sha | what it does (≤12 words) | verdict | reason (≤15 words) |
|-----|--------------------------|---------|-------------------|
| 93e6394e | Evals harness overhaul: new domains, runtime fixes | SKIP | Evals test infrastructure not in runtime ship |
| 563f9174 | Fix Router 409 idempotency conflict on refunded iterations | PORT | Cloud router bug fix; applies directly to intel fork |
| dbfc3420 | Fixed search bar focus, navigation, match highlighting | PORT | Chat search UX improvements; no special dependencies |
| 0b9733b9 | Fixed crashes and hangs | SKIP | PluginManager excluded; fixes likely plugin-specific |
| 784ab78a | Improve Telegram channel recovery diagnostics | SKIP | Telegram integration not in intel fork scope |
| 1e62218a | Minor tweak in favorite models UI | PORT | Model picker enhancement; applies to cloud providers |
| aa3c0279 | Add ChipProfile hardware capability detection | SKIP | ChipProfile is Apple Silicon detection; Intel only |
| 7b8fd86c | Batch diagnostics exposure and policy logging | SKIP | Local model batch diagnostics not applicable |
| 9839bc26 | CLI-like @ filesystem menu in chat input | PORT | Chat input enhancement; filesystem remapped for intel |
| 7d7df287 | Fix Codex model discovery gpt-5.5-*-wm slug issue | PORT | OpenAI provider fix; applies to intel cloud setup |
| f2db9127 | HY3 official: repin vmlx + load path fix | SKIP | vmlx is local GPU inference runtime; not in intel |
| 7bdb440f | Support Codex Responses Lite for GPT-5.6 models | PORT | OpenAI provider feature; applies to cloud models |
| 3dcd8f9b | Catalog-driven reasoning controls + model options unification | PORT | Reasoning UI applies to cloud model pickers |
| e1cea2b8 | Evals hermetic run storage isolation | SKIP | Evals test infrastructure; not in runtime ship |
| 7812da19 | Harden plugin and registry archive extraction | SKIP | Plugin system entirely excluded from intel fork |
| f8b1c02e | Product Hunt launch dialog (July 2026) | SKIP | Upstream marketing popup; not for intel fork |
| 8939ea3f | Make local-first onboarding immediately usable | PORT | Onboarding for cloud setup; applies to intel |
| 67eeaf0b | Show Product Hunt kitty next to dinosaur | SKIP | Upstream marketing popup; not for intel fork |
| b621603f | Stop gemma tool-loop, crashes, token rate fix | DEFER | Gemma/agent code entangled; thread fixes might isolate |
| b73015a2 | Request may only execute exposed tools | SKIP | Tool execution control specific to skills/agents |
| 3f4791e7 | Fixed MCP tool discovery paginated results | PORT | MCP bug fix; applies to intel MCP support |
| 286c4a9a | Fixed find bar crash scrolling partially rendered | PORT | Markdown search stability; no special dependencies |
| 07510e14 | Faster sandbox runtime, CoW rootfs, per-agent egress | SKIP | Sandbox subsystem entirely excluded from intel |
| 087b5ba9 | Agent request lifecycles independent of chat | SKIP | Agent subsystem entirely excluded from intel |
| 34d3f71c | Stop blocking main thread on HF keychain read | SKIP | HuggingFace model management not in intel fork |
| 2eac8d32 | Fixed window maximize bug | PORT | AppDelegate window state fix; applies to intel |
| ecb0b107 | Fix scheduled runs never completing | SKIP | Scheduled/background tasks tied to agent system |
| 3ddc5215 | Fixed main thread hangs: plugin/agent/streaming | DEFER | PluginManager/AgentsView excluded; streaming parts may apply |
| 84fc52ad | Pin vmlx for native 1-bit JANG support | SKIP | vmlx/JANG local model features not in intel |
| 8bd7106c | Make chat window responsive to narrow widths | PORT | Chat UI responsiveness; applies to all targets |
| 6d6d5dbf | Upgrade notch task navigation | SKIP | Notch task UI tied to amputated agent system |
| eaba91d0 | Fix Bonsai structured charts and memory safety | SKIP | Bonsai local model and skills system amputated |
| f3fce103 | Enforce selected memory safety limits | SKIP | Memory safety limits for local model loading |
| 504d174a | Improved AppleScript model search UX | SKIP | ModelDownloadView is local model management ui |
| 12ff17c7 | MCP bearer 401 classification | PORT | MCP authentication handling; applies to intel |
| 37bd1f03 | Universal skills library and tools-only agent UX | SKIP | Skills and agent subsystems entirely excluded |
| 61dad2f3 | Reduce redundant agent prompt context | DEFER | Agent prompts excluded; server context might benefit |
| 5aafd739 | Handle empty voice transcriptions | SKIP | Voice/TTS system amputated from intel fork |
| e99a2004 | Harden manual plugin receipt metadata | SKIP | Plugin CLI tool excluded from intel fork |
| 5c8257b9 | Redesign agent database workspace and settings | SKIP | Agent system and database tools entirely excluded |
| f8140597 | Redesign agent feature flags into abilities overview | SKIP | Agent subsystem entirely excluded from intel |
| d16b0676 | Premium web search via osaurus router | SKIP | Agent-specific feature; no chat-only equivalent |
| 1b955c2b | Added cmd+= and cmd+- font zoom shortcuts | PORT | Font zoom is generic UX feature; applies to intel |
| 96dfa9db | Knowledge collections system | SKIP | Extensive agent/knowledge system refactor excluded |
| 29ebe5c1 | Reliability audit: install integrity, ABI validation | SKIP | Plugin system validation excluded from intel |
| b82cdc50 | Add runtime installation doctor | SKIP | CLI tool development not in intel fork scope |
| 05a12963 | Stabilize watchers pane layout | SKIP | Watcher UI monitors local inference; not in intel |
| 58df852d | Add eval watcher scoreboard artifacts | SKIP | Evals infrastructure; not in runtime ship |
| e662e5b8 | Polish context budget popover | PORT | Chat UI polish; applies to all targets |
| 40c5e8b7 | Improve models catalog browsability | SKIP | ModelDownloadView is local model management |
| 2c76b904 | Normalize Bonsai recommendations for onboarding | SKIP | Bonsai local model not in intel fork |
| 34510060 | Fix AppleScript computer use finalization | SKIP | AppleScript/Computer Use system amputated |
| c8afeca2 | Redesign agent detail navigation and tools tab | SKIP | Agent system and UI entirely excluded |
| d7be8240 | Overhaul tools management UX | SKIP | Agent/plugin/tools UI all amputated |
| 4b96ae0a | Fix singular and plural count labels (50 files) | PORT | Localization fixes mostly generic; subset applies |
| c64b7499 | Fix JANG AppleScript success finalization | SKIP | AppleScript/JANG local model features amputated |
| 7b872e56 | Added knowledge base introduction modal | SKIP | Knowledge base feature is agent-specific |
| 8fd75506 | Track chat file changes with undo (47 files) | SKIP | Folder/workspace context is amputated |
| 2a280aaa | Add combined-mode file_copy bridge for binaries | SKIP | Folder tools and combined execution amputated |
| 3ba84c38 | Fix management-window sheet-swap crash | PORT | AppDelegate crash fix; applies broadly |
| f5009855 | Detect MCP URLs in API provider form | PORT | MCP provider UX; applies to intel |
| 48376dbf | Correct Gemma QAT cache settings | SKIP | Gemma local model cache management |
| 6b1e91f9 | Harden agent DB tool contracts | SKIP | Agent DB and database tools amputated |
| c75364a9 | Publish plugin active version atomically | SKIP | Plugin system excluded from intel |
| ea7ee07d | Fix Nemotron AIFF routing and cache | SKIP | Nemotron local model audio routing |
| d8962622 | Fix skill discovery metadata and MCP capability | DEFER | Skills excluded; MCP load improvements might extract |
| 12396f73 | Fix Bonsai hybrid detection; add eval coverage | SKIP | Bonsai local model and evals excluded |
| aba60912 | Fix gemma cache telemetry and bonsai charts | SKIP | Local model telemetry not in intel |
| 26fde677 | Isolate working-folder context per session (35 files) | SKIP | Folder/workspace execution context amputated |
| 1904e0ac | Move thinking toggle into model picker | PORT | Thinking mode UI; applies to cloud models |
| 03fad56f | Fixed app hangs (mixed causes) | DEFER | SandboxConfiguration excluded; other hangs assess case-by-case |
| 5e7a0d00 | Pin paged cache eviction fix | SKIP | Local model paged cache system excluded |
| 846ca918 | Preserve explicit thinking mode across tool turns | DEFER | Tool turns amputated; thinking preservation might extract |
| 9b5decf8 | Add openai compatible tts server support | SKIP | TTS system amputated; voice config not applicable |
| 08eb8bd8 | Fix prompt text deleted on escape | PORT | Chat input UX fix; applies broadly |
| 9b0331fd | Fix reasoning toggle across agent tool loops | DEFER | Tool loops amputated; reasoning toggle may isolate |
| 59334020 | Pin explicit gemma 4 paged cache support | SKIP | Gemma local model cache excluded |
| ac3a0417 | Continue cap-truncated file_read to end | SKIP | Folder tools amputated from intel |
| 6ae20356 | Pin chats in sidebar | PORT | Chat sidebar UX feature; applies broadly |
| 479133ba | Multi-select chats to delete/archive | PORT | Chat sidebar UX feature; applies broadly |
| 402060bc | Adopt native macOS theme defaults | PORT | Theme system applies to all targets |
| cee858bc | Fix AppleScript completion and SSD warmups | SKIP | AppleScript and SSD inference cache excluded |
| 8e61aa7f | Fix launch-time SSD prefix cache misses | SKIP | SSD cache for local models excluded |
| 1844ed29 | Native browser use: replace osaurus.browser | SKIP | Browser feature built on amputated plugin system |
| 2fed45ac | Restore SSD warmup prefixes across chats | SKIP | SSD cache for local inference excluded |
| 40aa9fa2 | Seatbelt sandbox fallback for macos 15 | SKIP | Sandbox entirely excluded from intel |
| 0dfbae5d | Wire laguna S2.1 runtime and cache controls | SKIP | Laguna S2.1 local model runtime excluded |
| 4daee7b3 | Fixed app hangs (18 files) | DEFER | ExternalModelLocator excluded; general hangs might extract |
| 22308112 | Context-optimization harness and evals | SKIP | Evals infrastructure; not in runtime ship |
| 01de80e6 | Fix computer use and applescript regressions | SKIP | Computer use/AppleScript entirely amputated |
| 0a2c6afc | Drain cancelled prefill before next chat | SKIP | Prefill system for local inference excluded |
| 9572fbb2 | Add browser use what's new | SKIP | Browser use feature entirely excluded |
| 80742e93 | Fix stream finalization and thinking control | PORT | Chat stream and reasoning UI; applies broadly |
| 187f7662 | Update Chinese translations | PORT | UI text localization; applies broadly |
| 450690b4 | Group consecutive thinking and tool activity | DEFER | Tool grouping amputated; thinking UI might extract |
| 5bb946f7 | Auto-generate chat titles | PORT | Chat title generation; applies to intel |

# Window 4

| sha | what it does (≤12 words) | verdict | reason (≤15 words) |
|---|---|---|---|
| d417cdf9 | Fix tool finalization and SSD cache warmup | SKIP | SSD cache is local inference (MLX), amputated |
| 58624563 | fix settings window not opening on sequoia | PORT | Generic AppDelegate fix, no subsystem deps |
| 6dc2f190 | fix mcp tool calls failing after slash command | SKIP | Skills subsystem amputated |
| 33628c71 | Fix Bonsai DB recovery and SSD prefix reuse | SKIP | Bonsai DB is local inference storage |
| b7fc8c3c | Preserve SSD warmup across chat lifecycle | SKIP | SSD cache is local inference feature |
| 11aaf495 | Report MCP tool envelope failures | PORT | Generic MCP error handling, portable |
| 554ace8e | Redact secret tool arguments across surfaces | PORT | Generic tool safety, portable |
| 4d6634f5 | Channels: multi-agent routing and setup | SKIP | Agent channels subsystem amputated |
| 98136734 | improved chat UX | PORT | Native thinking/tool views, portable |
| afa32e5c | Unify runtime policy and subagent delegation | DEFER | Entangled with amputated Agent subsystem |
| cc089802 | Fix Gemma and Qwen post-tool completion | PORT | Model-specific fixes, portable system |
| bda1c895 | Add connectivity-driven offline mode | PORT | Generic chat feature, portable |
| c820eb1d | fix: don't install CLI symlink into Homebrew | PORT | Build script, portable |
| 7ec54935 | Fix tracked tool completion and cache stability | PORT | Generic tool/cache handling, portable |
| e89be2de | Update Simplified Chinese and Traditional Chinese | PORT | i18n only, portable |
| 0046b7b4 | inject current date and timezone into user turn | PORT | Generic system prompt enhancement |
| 3c694182 | Stop completed agent runs reopening on todos | SKIP | Agent subsystem amputated |
| 74fa06ae | Add scored agent-loop and disk-cache proof gates | SKIP | Agent eval gates, amputated subsystem |
| 12c6de27 | fix factory reset hanging indefinitely | PORT | Onboarding/settings, portable |
| 03b6d2fe | Add proactive agent channel publishing | SKIP | Agent channel publishing subsystem |
| ca8bf281 | Fix stale Todo agent-loop completion | SKIP | Agent subsystem amputated |
| 1d17e9e0 | Fix settings prompt warmup cache invalidation | PORT | Cache/settings feature, portable |
| 98efd584 | Clarify channel messaging UX | SKIP | Channels subsystem (Agent), amputated |
| 92353afe | fix(i18n): two render sites that bypass localization | SKIP | Touches Voice/TTS subsystem (amputated) |
| 39e2d755 | added guardrails for factory reset auto quit | PORT | Generic onboarding safety, portable |
| f4d410da | Match assistant and user chat text sizing | PORT | Chat UI typography fix, portable |
| c8be96cc | fixed app hangs | PORT | Generic stability fixes, portable |
| 44548e90 | Native channel presence, formatting, reactions | DEFER | Channels subsystem, possibly MarkdownView portable |
| 2fa86dbb | Redesign channels UX: name-first destinations | SKIP | Agent channels subsystem amputated |
| 984debe2 | Harden keychain reliability on relaunch | PORT | Identity/keychain core, portable |
| bbad6ed9 | fix fireworks providers only showing 6 models | PORT | Provider system fix, portable |
| 33f455e4 | Fix selected-chat idle warmup recovery | SKIP | Local model warmup/residency system |
| 311f327c | import conversations from chatgpt, claude, grok | PORT | Chat import feature, portable |
| af68b064 | Fix plugin layout at compact widths | PORT | Generic UI layout fix |
| f013ccc7 | added chat import guide | PORT | Onboarding UI, portable |
| bfa62f65 | Add safe heterogeneous subagent batching | SKIP | Subagent/Agent batching subsystem |
| 0bbb9f7e | Add native iMessage agent channel | SKIP | Agent channels, system permissions new |
| 7f39220f | Make headless dispatches follow agent default | SKIP | Agent subsystem amputated |
| 3f73c480 | Make model-selector dot reflect true residency | PORT | Model selection UI, portable |
| f33c9eca | Unify subagent and server batching concurrency | SKIP | Agent batching subsystem amputated |
| e687fe3b | Add localized Channels What's New announcement | SKIP | Channels (Agent) subsystem amputated |
| 23e2b570 | Eliminate app hangs: unblock MainActor | DEFER | Generic threading + plugin host (amputated) |
| e3b1eac0 | Keep notch overlay pinned to screen edge | PORT | Generic UI fix, portable |
| d01aae61 | fix tool approval dialog overflow | PORT | Tool permission UI, portable |
| c81491b4 | Fix four reported runtime and model issues | PORT | Model/runtime fixes, portable |
| 11239f40 | fix tool permission panel sizing | PORT | Tool UI fix, portable |
| 00a23773 | i18n: split Server key (three UI elements) | SKIP | Touches TTS settings (Voice amputated) |
| 5212ffbc | fixed text selection in agent responses | PORT | Chat UI text selection, portable |
| 488062f7 | Fix explicit model unload and cache telemetry | PORT | Model cache management, portable |
| 2ecf2b05 | Make the Mac harness leaner and reliable | DEFER | Large refactor, touches both portable/amputated |
| 7c960b66 | Prevent stale whole-file rewrites | PORT | WorkspaceWriteSafety, portable |
| b6863d77 | Stabilize execution modes, prompts, cache | PORT | Generic stability feature, portable |
| 13ab0a18 | Harden AgentDB imports and saved views | SKIP | Agent DB subsystem amputated |
| 03557065 | Harden capability readiness and authorization | DEFER | Agent capabilities, depends on subsystem |
| 89ccb249 | Add redeemable credit codes | PORT | Router credits feature, portable |
| 757807f9 | Redeem code follow-ups: settle first-action gate | PORT | Credits feature, portable |
| 7969bc0e | Add DeepSeek V4 Flash 0731 app support | PORT | Model config addition, portable |
| 40ec9e83 | Add live task status indicators sidebar | PORT | Chat UI feature, portable |
| 55ffd834 | Pin DSV4 disk-prefix fix and eval proof | DEFER | Eval proofs possibly Agent-related |
| ce414b3f | Add LLM-powered context compaction | PORT | Cloud feature, portable |
| eee9c5cf | Revamp default Osaurus agent | SKIP | Agent subsystem amputated |
| d1d71402 | Report why disk cache disabled | DEFER | Likely local model cache diagnostic |
| d0b9502b | Add optional shadow style for chat input | PORT | Theme feature, portable |
| 3580502c | added /title slash command to name chats | PORT | Slash command feature, portable |
| 31d9ec56 | Remove generative greetings | PORT | Feature removal, chat experience fix |
| 1d927b91 | Expand onboarding tool picker | PORT | Onboarding UI, portable |
| 69519a14 | Add cloud image and video generation | PORT | Cloud feature, portable |
| 7508afab | Add one-time post-onboarding import prompt | PORT | Onboarding UI, portable |
| 79b25d6b | Improve activation telemetry | PORT | Telemetry enhancement, portable |
| 6daf54cb | Fix production crashes and hangs | PORT | Generic stability fixes, portable |
| b527d08b | Add System default theme card | PORT | Theme feature, portable |
| 84bdc5c8 | fix agent recovery for deferred tools | SKIP | Agent subsystem amputated |
| b12a646e | Fix DSV4 thinking default and context | PORT | Model config fix, portable |
| e06996e3 | surface keychain errors and recover ACL denials | PORT | Keychain reliability, portable |
| e0eeba12 | add cmd+n shortcut for new chat | PORT | Keyboard shortcut, portable |
| 42e64580 | Fix custom agent capability dispatch | SKIP | Agent capabilities subsystem |
| 16869043 | Allow importing private Hugging Face models | SKIP | ModelDownload subsystem amputated |
| 577a3eee | honor context windows from custom providers | PORT | Provider API support, portable |
| 180c4f3a | Improve agent abilities context guidance | SKIP | Agent subsystem amputated |
| 99537680 | fixed main thread hangs | PORT | Generic threading fixes, portable |
| ec38ab2a | Clarify model memory estimates and guidance | PORT | Model selection UI, portable |
| 5d16b603 | Clarify capability IDs and recover tool calls | DEFER | Capability system, possibly Agent-dependent |
| ee2fcecc | Fix sandbox plugin activation dependencies | SKIP | Sandbox subsystem amputated |
| f4340605 | Fix remaining sandbox reachability gaps | SKIP | Sandbox subsystem amputated |
| 13f8d7fd | Refresh MCP catalogs and streamline Tools | PORT | MCP/tools management, portable |
| 319b7c71 | Fix first-turn double prefill, cache hazards | DEFER | Model cache warmup, local model related |
| 06af55e7 | Bound capability group-load schemas | DEFER | Capability + vMLX, local model related |
| ffadbfdb | allow creating new folders in panels | PORT | Generic UI feature, portable |
| 85d53136 | added delete all data option | SKIP | Agent settings (amputated subsystem) |
| e9ab5551 | Let TTFT phase tracing be in release | PORT | Performance tracing, portable |
| bc6146f1 | Fix reasoning-only turn classification | PORT | Chat logic fix, portable |
| 02c141b9 | Give orphaned local-model lock way out | SKIP | Local model system (MLX) amputated |
| 13d04eb8 | minor UI polish | PORT | Generic UI improvement, portable |
| f3608d88 | Render $…$ inline math without delimiters | PORT | Markdown rendering, portable |
| 7b9cea55 | Start TTFT trace when user hits send | PORT | Performance tracing, portable |
| c4d9d140 | allow deleting individual assistant messages | PORT | Chat UI feature, portable |

# Window 5

| sha | what it does (≤12 words) | verdict | reason (≤15 words) |
|-----|--------------------------|---------|-------------------|
| 4e2bcb03 | Give a quarantined plugin one retry | SKIP | PluginManager subsystem amputated |
| 24bf2af2 | fix skill editor sheet clipping | SKIP | Skills subsystem amputated |
| a82aa144 | added full screen preview for generated images | PORT | Chat UX improvement; applies to mirrored ChatView |
| e7c4f22f | add follow up question suggestions after a turn | DEFER | Agent subsystem simplified; needs careful port |
| ccd310ed | Record a user Stop as cancelled not stop | PORT | Core chat correctness fix |
| 89c0f847 | fix model search placeholder overlapping IME | PORT | Search field accessibility fix |
| 092e81cf | Constrain reasoning_effort to bundle's set | PORT | Model configuration correctness |
| b9b8b7fc | Persist the cancelled marker when Stop beats delta | PORT | Background task correctness |
| 78b7ff8d | Attribute silent restarts: exit markers | PORT | App lifecycle correctness |
| bbd364be | Persist before stop in window cleanup | PORT | Window state correctness |
| 57b8ae96 | Treat bare channel name as blank thinking | PORT | String processing utility |
| affef475 | fix custom agents failing to spawn subagents | SKIP | Agent spawning amputated |
| 8a9d32ea | added projects support to group chats | PORT | Projects/chats core feature; 40-file port |
| e3a8f963 | added reasoning effort for zai-glm on mistral | PORT | Cloud provider model configuration |
| 035ed272 | make sidebar resizable | PORT | Chat UI enhancement |
| 2cc7faa2 | minor adjustments to project pill | PORT | Projects UI polish |
| 3877f5e9 | fix openai codex models context window | PORT | OpenAI provider correctness |
| a8283784 | Repin vmlx to staged-verify MTP | SKIP | vMLX/MTP local inference amputated |
| af76eae7 | Settings: DFlash 2 drafter picker | SKIP | DFlash 2/MTP local inference amputated |
| 092bbfcd | Fix the DFlash 2 drafter download link | SKIP | MTP local inference amputated |
| 21e5ed86 | Unload image gen/edit models from cache | SKIP | Local model cache management amputated |
| 03de9e23 | Video attachments silently dropped at send | PORT | Chat media attachment correctness |
| 218fcc9a | Images to remote providers: size, mime, drop | PORT | Chat media handling for cloud providers |
| febb1a25 | Make the MTP Mode hint tell the truth | SKIP | MTP local inference amputated |
| 90b86b81 | fit fixed size sheets to the screen | DEFER | AgentsView amputated; sheets might apply mixed |
| b7f86935 | Disk cache: auto-size to 10%, surface usage | DEFER | Cache system tied to local model caching |
| a153887c | Stop billing cold model load as TTFT | SKIP | InferenceProgressManager local inference only |
| a2e781be | Disk cache size is percent; stale GB reader | DEFER | HTTPHandler might apply; cache complex |
| 64bc6580 | Sampling Defaults were inert; show actual | DEFER | Mixed amputated/live; needs careful port |
| 6b6bd6e5 | An audio-capable model could not receive audio | PORT | Audio media support for cloud models |
| 7da5dfdb | Audio coverage: third family, depth limit | PORT | Audio UI badge on model chip |
| 23752181 | Only an explicit Repair may rebuild bundle | SKIP | Bundle management local inference specific |
| 138d7d17 | api (ollama): add capabilities to response | SKIP | Ollama local inference only amputated |
| f01e5d44 | fix xai oauth models reporting stale catalog | PORT | XAI cloud provider OAuth correctness |
| bce51e0f | hardcode openai context windows as api | PORT | OpenAI context window correctness |
| 00cdfa34 | attach granted plugin tools to channel | SKIP | Plugin system amputated |
| 86ddcdd3 | keep cross-chat prefill reusable by stabilizing | PORT | System prompt template correctness |
| dbe6a508 | fix wasted warm ups and context tooltip | DEFER | "warm ups" likely local model loading |
| 553dde22 | Adopt bundle's presence/frequency penalties | SKIP | LiveActivitySection local inference monitoring |
| 27296c39 | Say why speculative decoding is not running | SKIP | MTP speculative decoding amputated |
| cc19e771 | fixed main thread hangs | PORT | CreditsView correctness (Osaurus Router) |
| d9a1a066 | add bulk edit and redaction tools for folder | PORT | Folder chat tools live feature |
| 6a865fd5 | Show the drafted width and stop unusable | SKIP | MTP speculative depth specific |
| 556d0189 | let agents write knowledge directly with approval | DEFER | Agent knowledge feature; 66-file refactor |
| f0e5a1be | Redesign onboarding as a 3-screen | DEFER | Onboarding involves amputated agent config |
| 1faccfa2 | minor improvements in onboarding | PORT | Onboarding UX polish |
| 8d7c3dd4 | Default-agent config + delegation orchestrator | DEFER | 195-file agent orchestrator refactor |
| 62f98b47 | Speculative Depth row rendered with no MTP | SKIP | MTP specific |
| 7aa8d7a3 | Introduce Orchestrator: settings tab, identity | DEFER | Orchestrator depends on amputated agents |
| 6ecd2133 | Migrate credit system UI from dollars to | PORT | Osaurus Router credit UI migration |
| 679ba750 | Orchestrator-first delegation: spawn, artifacts | DEFER | Orchestrator delegation amputated |
| 8a8f01ec | fix(chat): render display math stable | PORT | Markdown LaTeX rendering correctness |
| 8aa97c06 | Onboarding polish: motion, Figma bubble | DEFER | Onboarding structure simplified in fork |
| 64f54a67 | Delete persisted global Disable Tools switch | SKIP | Plugin/tool system amputated |
| bb3cc32d | Promote Orchestrator to documented feature | SKIP | Orchestrator feature not in fork |
| bf1996f3 | Speculative Depth buttons enforce real MTP | SKIP | MTP specific |
| f4b6ffa5 | chat UX improvements | PORT | Floating input card UX enhancements |
| d4409d6e | Single surfaced greedy-while-MTP coercion | SKIP | MTP specific |
| a9d2a150 | Swap-pressure warning banner + emulation | PORT | Memory swap warning UI useful generally |
| 29fedb38 | improved memory swap banner | PORT | Swap warning UI polish |
| 1b58dcf9 | Swap banner copy: name swap and measured GB | PORT | Swap warning text polish |
| 5523962d | revamped settings | DEFER | Large UI refactor conflicts with fork |
| bebc6f3f | fix settings crash on macos 15 tabs | SKIP | macOS 15+ outside fork's macOS 13 |
| 3d9f789c | fix permissions view showing disk access | PORT | System permissions correctness |
| fd53b118 | Agent loop: record exit branch telemetry | SKIP | Evals/agent telemetry only |
| 0daa7303 | Enable sandboxing by default | SKIP | Sandbox subsystem amputated |
| d341cfcd | Evals: explicit fail-closed native-MTP | SKIP | Evals MTP testing amputated |
| c853ca4c | Spawn admission: price by bounded request | DEFER | Spawn pool agent-specific |
| dd9de43f | simplify tools and plugins in settings | SKIP | Plugin/tool UI management amputated |
| bd5cc8d8 | Remove hidden Orchestrator tool kill switch | SKIP | Orchestrator not in fork |
| 98459196 | Preserve explicit reasoning on cold send | PORT | Reasoning preference correctness |
| 24133adc | Evals: preserve exit and cache taxonomy | SKIP | Evals only |
| 31aa9ab5 | Repin vMLX for Ornith 35B MTP safety | SKIP | vMLX/MTP amputated |
| 1e6faebc | Make batch evals architecture-aware | SKIP | Evals only |
| 0129221a | Warn when switching models mid-conversation | PORT | Chat UX safety warning |
| 78fccf9c | Make denied chat tool outcomes visible | SKIP | Tool denial plugin-specific |
| 1517ceac | Give loaded skills directory anchor | SKIP | Skills subsystem amputated |
| eca456c3 | Add Claude Code CLI integration | PORT | Intel hand-port: CLI discovery/auth, safe text streaming, picker routing, and process teardown; MCP agent mode remains roadmap work |
| 4137884f | Recover media rejections and harden OpenAI | PORT | Media and OpenAI provider hardening |
| 1f052d17 | Show and cancel exact live inference work | DEFER | Live activity UI local inference tied |
| 96b05d20 | Hide local memory warnings for cloud models | PORT | Cloud model UX improvement |
| edab3c63 | Fix stale agent completion and bundles | SKIP | Evals only |
| 11cd0c90 | Preserve cache checkpoints across dispatch | SKIP | External model local inference only |
| ca2f8b73 | Use Raptor for mainstream onboarding | DEFER | Depends on onboarding structure |
| 62664a08 | added raptor v0.5 in what's new modal | DEFER | Model download/management not cleaned |
| 0555885c | fix theme editor freezes | PORT | Theme system correctness |
| 1d46deee | Evals: cache write/reuse per tool call | SKIP | Evals only |
| 07d9243c | Model picker: resolve local effort live | SKIP | "local effort" local model reasoning |
| ee851603 | added source filter to model picker local | SKIP | "local tab" local models only |
| ecd027a9 | fix unreadable approval in tool modal | SKIP | Plugin/tool approval amputated |
| f13e429b | added custom endpoint support to onboarding | PORT | Custom endpoint config valuable |
| e03127e7 | Watcher/dispatch agents reach target folder | DEFER | Watcher/dispatch agents amputated |

