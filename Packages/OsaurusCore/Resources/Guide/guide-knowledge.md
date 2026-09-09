---
title: Knowledge Collections
summary: Curated folders of documents that agents search and read on demand — human-governed, never modified without approval.
order: 105
---

# Knowledge Collections

Knowledge is what you teach your agents: a library of your own documents (SOPs, templates, standards, how-tos) that granted agents search and read on demand. Memory is what an agent learns from conversations; knowledge is explicit, versioned, and human-governed.

## Setup

1. Management (⌘⇧M) → Knowledge → **Add Collection** — point it at any folder of guides, templates, standards, or an exported wiki.
2. Open a custom agent → Abilities → Overview → **Knowledge** — enable the toggle and choose the collections that agent may use.
3. Chat. The agent can search, list, and read the granted library when a task calls for it.

Files are indexed in place and never moved or modified. Markdown, MDX, and plain text are read directly. PDF, Word, Excel, PowerPoint, CSV, source-code, and other formats supported by Osaurus's document adapters are converted to searchable text locally. Optional YAML frontmatter (`type`, `title`, `description`, `tags`) improves filtering and display.

Projects can share collections too. Open a project and select collections in its **Knowledge** section; every chat in that project receives those collections in addition to the running custom agent's own grants.

## Grants and safety

- Grants are per agent and enforced when a search or read runs — an agent cannot reach a collection it was not granted.
- Disabling a collection removes it from retrieval while keeping its registration available for later.
- Retrieval is read-only. The Knowledge UI never writes into the selected folder.
- The index is derived data. The folder remains the source of truth and can be backed up or edited independently.

## Read-only by design

This Intel release restores retrieval first. Agents receive `search_knowledge`, `list_knowledge`, and `read_knowledge`; they cannot alter the selected folders. The later curation milestone can add stale-document tickets and human-reviewed proposals, with approval remaining the explicit boundary for every write.

## Limits and storage

The registry and derived index live under `~/.osaurus/knowledge/`. Indexing accepts up to 5,000 files per collection, with a 2 MB limit for text and a 10 MB limit for adapted documents. Removing a collection deletes only its registry entry and derived index rows; it never deletes the selected source folder.

The SQLCipher index is disposable. If a copied index belongs to another device key, is corrupt, or uses a newer schema, Osaurus quarantines only `knowledge.sqlite` and its sidecars under `~/.osaurus/knowledge/quarantine/`, then rebuilds from the copied collection registry and original source folders. The cached local `potion-base-8M` model adds semantic search; full-text search remains available without it.
