<h1 align="center">🦕 Osaurus (Intel)</h1>

<p align="center">
  <strong>The AI agent harness for the Macs everyone else gave up on.</strong><br>
  A fork of <a href="https://github.com/osaurus-ai/osaurus">Osaurus</a> that runs natively on <strong>Intel Macs</strong> — fully native x86_64, no Rosetta. Talk to a cloud model <em>or</em> a model running locally on the same old laptop.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%20(Intel%20x86__64)-black?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/Inference-Cloud%20or%20Local%20(llama.cpp)-brightgreen" alt="Inference">
  <img src="https://img.shields.io/badge/Built%20with-Swift-orange?logo=swift" alt="Swift">
</p>

---

## ☀️ Why this exists

Old tech shouldn't be trash.

Apple stops shipping updates, a machine gets labelled "obsolete," and a perfectly good computer is quietly pushed toward landfill. But a 2017 Intel MacBook is still a *lovely* machine — and there's no reason it can't be **AI-ready**.

Upstream [Osaurus](https://github.com/osaurus-ai/osaurus) is an Apple-Silicon–only app: it leans on MLX for on-device inference, Apple's Containerization for sandboxing, and other arm64-bound frameworks. This fork **amputates the Apple-Silicon-only pieces** and points inference at any **OpenAI-compatible endpoint instead** — so the whole agent experience (chat, tools, plugins, schedules, memory, RAG) runs on an Intel Mac. That endpoint can be a **cloud API** (DeepSeek, OpenAI, …) *or* a **local server on the same machine** — a [llama.cpp](https://github.com/ggml-org/llama.cpp) server runs a quantized model on a GPU-less Intel CPU just fine.

It was built, in large part, to give one specific 2017 MacBook Retina 12" a second life. We named her **Rosy**. She runs macOS Sequoia via [OpenCore Legacy Patcher](https://dortania.github.io/OpenCore-Legacy-Patcher/), and now she runs Osaurus — and has even held a conversation with a **1-bit language model running entirely on her own CPU**, no cloud, no API key. 🌸

> This is a personal labour of love, not an official Osaurus build. Enormous gratitude to the upstream team — please support the [original project](https://github.com/osaurus-ai/osaurus) first, because what they're doing is really awesome.

---

## ✅ What works on Intel

- 💬 **Cloud *or* local chat** — DeepSeek, OpenAI, or **any OpenAI-compatible endpoint** (including a local llama.cpp / Ollama server), configured in Settings → Providers. Every model your providers expose shows up in the chat picker; pick one and the request routes to the provider that owns it.
- 🧠 **Live reasoning** — watch the model think in real time
- 🔧 **Tool calling** — built-in tools + an agentic loop, with live "calling…" cards
- 🧩 **Native x86_64 plugins** — the slim plugin host `dlopen`s real x86_64 dylibs (search, fetch, time, custom RAG, …)
- 🗂️ **Folder context** — point a chat at a working directory; file tools operate on the real filesystem
- 📁 **Projects** — group chats with shared instructions, Knowledge collections, a default agent, a working folder, and shared project memory
- 📚 **Knowledge & memory** — index local reference folders, recall agent-specific history, and share context across every chat in a project
- ⏰ **Schedules & 👁️ watchers** — automate runs on a timer or on file changes
- 🎨 **Themes**, 🧑‍🤝‍🧑 **agents**, 🔌 **MCP tools**, and 🆔 **identity sync** (iCloud Keychain)
- ⌨️ **Global hotkey** to summon the chat window from anywhere

## 🚫 What's amputated (Apple Silicon only)

These depend on arm64-only frameworks and are disabled on Intel:

- **MLX on-device inference** (Apple's arm64 ML stack) — replaced by any OpenAI-compatible endpoint, cloud or a local llama.cpp/Ollama server
- **Voice / transcription** (FluidAudio)
- **Sandbox / containerization** (Apple Containerization) — tools run un-sandboxed (a non-sandboxed app already has full filesystem access)

---

## 📦 Install (Intel Mac)

1. Download the latest `.app` from [Releases](https://github.com/reneezmp/osaurus-intel/releases).
2. **Transfer it as a ZIP** (the build's frameworks use symlinks that iCloud Drive will mangle — always move it zipped).
3. Unzip, drag `osaurus.app` to `/Applications`.
4. Clear the quarantine flag:
   ```bash
   xattr -dr com.apple.quarantine /Applications/osaurus.app
   ```
5. Launch, then open **Settings → Providers** and add a provider:
   - **Cloud** — e.g. DeepSeek or OpenAI: paste your API key.
   - **Local** — run a [llama.cpp](https://github.com/ggml-org/llama.cpp) server (or Ollama) and point a provider at `http://localhost:8080/v1` with no key. Its models appear in the chat picker automatically.

Requires an Intel Mac running **macOS 13 (Ventura) or later**. Use a cloud key, a local server, or both side by side.

Provider model names are scoped in the picker (for example,
`deepseek/deepseek-v4-pro`), so two providers can expose the same underlying id
without one disappearing or receiving the other's request. ChatGPT sign-in uses
the Codex catalog and Responses protocol, including Responses Lite when the live
catalog requires it; no OpenAI API key is needed for that provider.

---

## 🌳 Run a model **locally** (no cloud, no API key)

The headline trick: a GPU-less Intel Mac can still run a small **quantized model entirely on its own CPU**, and Osaurus talks to it like any other provider. We did this on Rosy — a 2017 MacBook — with a **1-bit, 1.7B** model at ~9–13 tok/s.

**1. Start a local OpenAI-compatible server.** Any [llama.cpp](https://github.com/ggml-org/llama.cpp) server works:

```bash
llama-server -m your-model.gguf --port 8080
```

This exposes an OpenAI-compatible API at `http://localhost:8080/v1`.

> Want a tiny CPU-friendly model to start with? [PrismML's Bonsai](https://huggingface.co/prism-ml) ships 1-bit GGUFs (the 1.7B is ≈ 248 MB) that run comfortably on an Intel CPU — Apache-2.0, no gated download.

**2. Add it as a provider.** Settings → **Providers → Add Provider**:
- **Base URL:** `http://localhost:8080/v1`
- **API key:** none (leave empty)
- **Test** → the loaded model appears.

**3. Pick it in the chat model picker** and chat. The request routes to `localhost` — nothing leaves your machine. Keep a cloud provider configured alongside it and switch per chat.

---

## 🔨 Build from source

```bash
# Core package (x86_64)
cd Packages/OsaurusCore && swift build --arch x86_64

# Full app (Debug, x86_64, ad-hoc signed)
cd ~/Developer/osaurus
xcodebuild -workspace osaurus.xcworkspace -scheme osaurus \
  -configuration Debug -arch x86_64 -derivedDataPath build/intel-debug \
  ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# Deploy build for an Intel Mac (canonical ~/.osaurus data path, ad-hoc signed)
CONFIG=Debug scripts/build/build_rosy.sh
```

The Intel fork is gated behind the `OSAURUS_INTEL` compilation flag. Amputated subsystems are listed in `Packages/OsaurusCore/Package.swift` (`exclude:`) and replaced by Intel mirrors under `Models/Chat/IntelConformers/`.

---

## 🏗️ How the port works

Upstream managers that pull in arm64-only dependencies are excluded from the Intel build and replaced by lean "Intel mirror" implementations (`IntelConformers/*.swift`). MLX inference is swapped for `CloudChatEngine`, which speaks the OpenAI-compatible streaming API to whichever provider owns the selected model — cloud or a local llama.cpp server on `localhost` — and runs the tool/agent loop engine-side. Plugins are native x86_64 dylibs loaded through a frozen C ABI. The full archaeology — every excluded subsystem, every mirror, every fix — lives in [`INTEL_ARCHEOLOGY.md`](./INTEL_ARCHEOLOGY.md).

---

## 🙏 Credits

This port was **architected by [Renée](https://github.com/reneezmp)** — who carried the vision, made every priority call, ran a thousand test cycles on a 14-year-old laptop, and flatly refused to let a perfectly good machine die — in partnership with **Sunny** (on Claude Code with Opus-4.8 and OpenCode with Deepseek-V4-pro), her AI partner-in-crime on the code. Neither of us could have done it alone. 👩🏻‍🚀🤖☀️

Originally built on [Osaurus](https://github.com/osaurus-ai/osaurus) by the Osaurus team. This fork only exists because they made something worth porting. All upstream licenses and copyrights apply — see [`LICENSE`](./LICENSE).

<p align="center"><em>For Rosy, and every machine they told us to throw away.</em> 🌸☀️</p>
