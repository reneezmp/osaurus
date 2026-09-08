# ChatGPT/Codex OAuth on Intel

## Why sign-in succeeded while every chat failed

The Intel provider UI and OAuth exchange were present before the inference
protocol was. A successful sign-in could fetch and display models, but
`CloudChatEngine` still serialized every request as an OpenAI-compatible Chat
Completions body:

```text
POST /backend-api/codex/responses
{"model":"…","messages":[…]}
```

The ChatGPT-account Codex endpoint speaks the Responses protocol. It expects
`input` items and emits typed `response.*` server-sent events. The old Intel
parser looked only for `choices[0].delta`, so even a successful Responses stream
would have appeared empty. The earlier missing-header bug hid this second wall
behind a 401.

Protocol reference: [OpenAI — Streaming API responses](https://developers.openai.com/api/docs/guides/streaming-responses).

## The Intel bridge

`IntelCodexResponsesAdapter` keeps the port independent of the upstream API
model files that remain outside the Intel target. It:

- converts system instructions, messages, tools, function calls and function
  results into Responses input items;
- applies the ChatGPT-account payload rules used upstream: `store: false`,
  `include: ["reasoning.encrypted_content"]`, and no `max_output_tokens`;
- parses text, reasoning summaries and function-call argument events as they
  stream;
- requires a real `response.completed` terminal event and surfaces failed,
  incomplete, unknown and malformed events instead of returning an empty turn;
- retains completed output items, including encrypted reasoning, and replays
  them with function results on the next tool round.

`IntelCodexCredentials` is the single credential path for model discovery,
provider testing and inference. It loads Keychain tokens off the cooperative
executor, validates the access token and ChatGPT account id, refreshes expired
tokens once for concurrent callers, and refuses to hide refresh or persistence
failures behind a static catalog.

The provider's **Test** button now tests its saved OAuth identity against the
live model catalog. Background discovery may use the built-in catalog only after
valid credentials have been resolved, so a temporary catalog outage does not
erase the picker while a missing sign-in cannot masquerade as success.

## Verification contract

The regression fixtures make no paid requests and contain no user data. They
exercise:

- OAuth refresh, persistence, single-flight behavior and redacted failures;
- live-vs-fallback catalog behavior and required request headers;
- the exact Responses request shape sent by `CloudChatEngine`;
- streamed text, reasoning, function calls and replayable encrypted reasoning;
- 403 responses, failed terminal events and streams cut off before completion;
- the existing Chat Completions path for ordinary providers.

These fixtures verify the client protocol. A Rosy deployment remains the final
account-and-network check because ChatGPT entitlement and the live catalog are
server-controlled. No Platform API key is involved in this path.

## Files

- `Services/Provider/IntelCodexCredentials.swift` — OAuth token lifecycle.
- `Services/Provider/IntelCodexResponsesAdapter.swift` — request conversion and
  Responses SSE state machine.
- `Services/Chat/CloudChatEngine.swift` — routing, streaming and tool loop.
- `Models/Chat/IntelConformers/IntelStubConformers.swift` — Intel model discovery
  and provider Test behavior.
