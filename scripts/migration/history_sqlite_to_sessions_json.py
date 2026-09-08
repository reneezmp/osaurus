#!/usr/bin/env python3
"""
Convert an upstream Osaurus `history.sqlite` chat database into the one-JSON-
file-per-session format the Intel fork reads from ~/.osaurus/sessions/.

Upstream (Apple Silicon) persists chats in SQLCipher/SQLite; the Intel fork
persists them as `~/.osaurus/sessions/<UUID>.json`. Same conversations, two
storage formats. This bridges them.

The Intel loader (`ChatSessionsManager.loadFromDisk`) skips any file it cannot
decode, silently and with no per-file log line. So this script is deliberately
paranoid: it validates every enum value against the Swift side's raw values,
truncates timestamps to whole seconds (Foundation's plain .iso8601 strategy
rejects fractional seconds), and drops individual malformed sub-objects rather
than risk failing a whole conversation's decode.

Usage:
    osaurus-history-to-json.py <history.sqlite> <output-dir>
"""

import json
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

# Agent.defaultId — Models/Agent/Agent.swift. A session whose agent_id is NULL
# must get this explicitly: the Intel decoder's fallback for an absent agentId
# is a *random* UUID, which differs on every load and hides the session from
# the "all agents" sidebar view.
DEFAULT_AGENT_ID = "00000000-0000-0000-0000-000000000001"

# SessionSource raw values (IntelDataConformers.swift). An unrecognized value
# fails the enum decode and takes the whole session with it.
VALID_SOURCES = {"chat", "plugin", "http", "schedule", "watcher", "self_schedule", "imported"}

# MessageRole raw values (InternalMessage.swift).
VALID_ROLES = {"system", "user", "assistant", "tool"}

# Attachment.Kind discriminators (Attachment.swift). Anything else throws
# dataCorruptedError and cascades up through the turn to the session.
VALID_ATTACHMENT_TYPES = {
    "image", "document", "audio", "video",
    "image_ref", "document_ref", "audio_ref", "video_ref",
}


def iso(epoch):
    """Whole-second ISO-8601 UTC. Foundation's .iso8601 strategy uses
    .withInternetDateTime only — fractional seconds fail to parse."""
    if epoch is None:
        return None
    return datetime.fromtimestamp(float(epoch), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def norm_uuid(value, fallback=None):
    if value is None or str(value).strip() == "":
        return fallback
    try:
        return str(uuid.UUID(str(value))).upper()
    except (ValueError, AttributeError):
        return fallback


def parse_json(raw, expected):
    if raw is None or str(raw).strip() == "":
        return None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    return parsed if isinstance(parsed, expected) else None


def clean_attachments(raw):
    """Keep only attachments whose `kind.type` the Swift decoder recognizes."""
    items = parse_json(raw, list)
    if not items:
        return []
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        if not isinstance(kind, dict) or kind.get("type") not in VALID_ATTACHMENT_TYPES:
            continue
        aid = norm_uuid(item.get("id"), fallback=str(uuid.uuid4()).upper())
        entry = {"id": aid, "kind": kind}
        meta = item.get("structuredDocumentMetadata")
        if isinstance(meta, dict):
            # `StructuredDocumentAttachmentMetadata.createdAt` is a Swift `Date`,
            # and the loader decodes with .iso8601 — but upstream serialized it
            # into this blob as a raw epoch number. Left as a number it throws
            # typeMismatch, which cascades up and drops the whole conversation.
            meta = dict(meta)
            raw_created = meta.get("createdAt")
            if isinstance(raw_created, (int, float)):
                meta["createdAt"] = iso(raw_created)
            entry["structuredDocumentMetadata"] = meta
        out.append(entry)
    return out


def clean_tool_calls(raw):
    """Normalize to {id, type?, function:{name, arguments}}."""
    items = parse_json(raw, list)
    if not items:
        return None
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        fn = item.get("function") if isinstance(item.get("function"), dict) else {}
        call = {
            "id": str(item.get("id") or ""),
            "function": {
                "name": str(fn.get("name") or ""),
                "arguments": str(fn.get("arguments") or ""),
            },
        }
        if item.get("type") is not None:
            call["type"] = str(item["type"])
        if item.get("geminiThoughtSignature") is not None:
            call["geminiThoughtSignature"] = str(item["geminiThoughtSignature"])
        out.append(call)
    return out or None


def clean_tool_results(raw):
    """toolResults is [String: String] on the Swift side — coerce values."""
    parsed = parse_json(raw, dict)
    if not parsed:
        return {}
    return {
        str(k): v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
        for k, v in parsed.items()
    }


def convert(db_path, out_dir):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    turns_by_session = {}
    for t in conn.execute("SELECT * FROM turns ORDER BY session_id, seq"):
        turns_by_session.setdefault(t["session_id"], []).append(t)

    written = skipped = dropped_turns = 0
    stats = {"no_agent": 0, "bad_source": 0, "attachments": 0, "tool_calls": 0}

    for s in conn.execute("SELECT * FROM sessions"):
        sid = norm_uuid(s["id"])
        if sid is None:
            skipped += 1
            continue

        created = iso(s["created_at"]) or iso(0)
        updated = iso(s["updated_at"]) or created

        agent_id = norm_uuid(s["agent_id"])
        if agent_id is None:
            agent_id = DEFAULT_AGENT_ID
            stats["no_agent"] += 1

        source = s["source"] if s["source"] in VALID_SOURCES else "chat"
        if s["source"] not in VALID_SOURCES:
            stats["bad_source"] += 1

        turns = []
        for t in turns_by_session.get(s["id"], []):
            role = t["role"]
            if role not in VALID_ROLES:
                dropped_turns += 1
                continue
            # A turn with no id would fail the whole session's decode. Synthesize
            # a stable one from the session id and sequence rather than lose the
            # conversation.
            tid = norm_uuid(
                t["id"],
                fallback=str(uuid.uuid5(uuid.UUID(sid), f"turn-{t['seq']}")).upper(),
            )
            turn = {
                "id": tid,
                "role": role,
                "content": t["content"] or "",
                "createdAt": iso(t["created_at"]) or created,
            }
            if t["thinking"]:
                turn["thinking"] = t["thinking"]
            atts = clean_attachments(t["attachments"])
            if atts:
                turn["attachments"] = atts
                stats["attachments"] += len(atts)
            calls = clean_tool_calls(t["tool_calls"])
            if calls:
                turn["toolCalls"] = calls
                stats["tool_calls"] += len(calls)
            if t["tool_call_id"]:
                turn["toolCallId"] = t["tool_call_id"]
            results = clean_tool_results(t["tool_results"])
            if results:
                turn["toolResults"] = results
            completed = iso(t["completed_at"])
            if completed:
                turn["completedAt"] = completed
            if t["generation_token_count"] is not None:
                turn["generationTokenCount"] = int(t["generation_token_count"])
            if t["time_to_first_token"] is not None:
                turn["timeToFirstToken"] = float(t["time_to_first_token"])
            turns.append(turn)

        session = {
            "id": sid,
            "title": s["title"] or "New Chat",
            "createdAt": created,
            "updatedAt": updated,
            "agentId": agent_id,
            "source": source,
            "archived": bool(s["archived"]),
            "pinned": bool(s["pinned"]),
            "capabilities": [],
            "turns": turns,
        }
        for key, col in (
            ("sourcePluginId", "source_plugin_id"),
            ("externalSessionKey", "external_session_key"),
            ("selectedModel", "selected_model"),
        ):
            if s[col]:
                session[key] = s[col]
        for key, col in (("dispatchTaskId", "dispatch_task_id"), ("projectId", "project_id")):
            val = norm_uuid(s[col])
            if val:
                session[key] = val

        path = out_dir / f"{sid}.json"
        path.write_text(
            json.dumps(session, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        written += 1

    conn.close()
    print(f"wrote {written} session file(s) to {out_dir}")
    print(f"  sessions skipped (unusable id): {skipped}")
    print(f"  turns dropped (unknown role):   {dropped_turns}")
    print(f"  sessions given the default agent: {stats['no_agent']}")
    print(f"  sessions with an unknown source:  {stats['bad_source']}")
    print(f"  attachments kept: {stats['attachments']}   tool calls kept: {stats['tool_calls']}")
    return written


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    convert(sys.argv[1], sys.argv[2])
