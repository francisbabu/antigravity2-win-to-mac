# How Antigravity 2.0 Stores Sessions & Why Naive Migration Fails

When migrating **Google Antigravity 2.0 (AGY 2.0)** from Windows (`C:\Users\<User>\.gemini`) to macOS (`~/.gemini`), simply copying the `.gemini` folder and running a global `sed` find-and-replace will either fail to show your conversations under projects or corrupt your session databases entirely.

This document explains the internal architecture of Antigravity 2.0's session storage and how `antigravity2-win-to-mac` solves each platform hurdle.

---

## 1. Storage Architecture Overview

```text
~/.gemini/
├── projects.json                          # Plain JSON: Maps project UUIDs & paths
├── trustedFolders.json                    # Plain JSON: Workspace trust & folder permissions
├── config/
│   ├── config.json                        # Plain JSON: Global AGY preferences
│   ├── mcp_config.json                    # Plain JSON: MCP server commands & file paths
│   ├── plugins/                           # Plain JSON: Installed plugin configurations
│   └── projects/
│       └── <project-uuid>.json            # Plain JSON: Per-project workspace root URI & metadata
└── antigravity/
    ├── conversation_summaries.db          # SQLite DB (WAL mode): Binary Protobuf BLOBs per conversation
    ├── agyhub_summaries_proto.pb          # Binary Protobuf snapshot of sidebar conversation summaries
    ├── conversations/
    │   └── <conversation-uuid>.db         # SQLite DB (WAL mode): Binary Protobuf trajectory steps
    ├── brain/
    │   └── <conversation-uuid>/           # Markdown artifacts (task.md, implementation_plan.md, etc.)
    ├── annotations/                       # Per-conversation user annotations
    ├── knowledge/                         # Knowledge base items
    └── skills/                            # Custom skills (may contain NTFS junctions on Windows)
```

---

## 2. The Four Pitfalls of Manual Migration

### Pitfall 1: Corrupting Binary Protobuf (`BLOB`) Columns with `sed`
In Antigravity 2.0, `conversation_summaries.db`, `conversations/*.db`, and `agyhub_summaries_proto.pb` store serialized **Protocol Buffers** (`BLOB` columns).
- Every string inside a Protobuf message is preceded by a **varint byte-length prefix**.
- If you run `sed` or string replacement on `.db` or `.pb` files (for example, replacing `D:\Projects` [11 bytes] with `/Users/you/Developer/projects` [29 bytes]), the string length no longer matches the Protobuf wire header, causing the Go `language_server` to fail deserialization and drop all conversations.
- **How project grouping actually works:** Antigravity's sidebar groups conversations under projects using `trajectoryMetadata.projectId` (a UUID like `634174a8-8b83-4037-bc68-dc0a7948b5b2`), which links to `~/.gemini/config/projects/<project-uuid>.json`.
- **Solution:** Only rewrite paths inside the plain-text `.json` configuration files (`~/.gemini/config/**/*.json`, `projects.json`, `trustedFolders.json`) and `.md` artifacts. Leave `.db` and `.pb` files bit-for-bit intact.

### Pitfall 2: Uncheckpointed SQLite Write-Ahead Logs (`.db-wal`) on Windows
While Antigravity is running on Windows, SQLite opens `conversation_summaries.db` and active `conversations/<uuid>.db` in **WAL (Write-Ahead Logging)** mode.
- Recent conversation turns live inside `.db-wal` until SQLite checkpoints them on graceful shutdown.
- Furthermore, copying raw `.db-shm` (shared-memory mmap) and `.db-wal` files across operating systems can cause SQLite lock or recovery mismatches on macOS.
- **Solution:** `windows/export-antigravity.ps1` gracefully stops `Antigravity` first, waits 3 seconds for `language_server` to checkpoint all `.db-wal` buffers into the main `.db` files, and excludes `*.db-shm` / `*.db-wal` lock files from the archive.

### Pitfall 3: macOS `runInBackground` Daemon Overwriting Imported Summaries
On macOS (`darwin`), Antigravity defaults to `runInBackground = true` (staying alive in the macOS menu bar tray even after you close all windows).
- If you launched Antigravity on your new Mac *before* importing your sessions, `language_server` starts with `0` conversations in memory.
- If you merely close the Antigravity window (or gracefully quit `Antigravity.app`) after extracting your files, the background `language_server` either stays alive serving its empty in-memory state (`resident: 0 -> 0`) or flushes its empty in-memory `SummariesState` over your freshly extracted `agyhub_summaries_proto.pb` on shutdown!
- **Solution:** `macos/import-antigravity-mac.sh` and `macos/reload-antigravity-mac.sh` send `SIGKILL` (`killall -9 Antigravity language_server`) *before* extracting the archive so the stale daemon cannot overwrite the imported summary store on exit.

### Pitfall 4: Windows NTFS Junctions (`ReparsePoint`) Breaking `tar.exe`
Some Antigravity plugins create Windows NTFS directory junctions inside `~/.gemini/antigravity/skills/`. If the target plugin directory is removed or excluded, `tar.exe` on Windows fails when attempting to dereference a dangling junction.
- **Solution:** `windows/export-antigravity.ps1` inspects `FileAttributes::ReparsePoint` on every skill entry and skips NTFS junctions automatically.
