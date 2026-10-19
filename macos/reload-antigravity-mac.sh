#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0: Force-Reload Summary Store on macOS
# ==============================================================================
# Use this script if your projects appear in the Antigravity sidebar on macOS,
# but the conversations under each project are missing (caused by macOS keeping
# an older background `language_server` process alive in the menu bar tray).
# ==============================================================================

set -euo pipefail

ARCHIVE_PATH="${1:-}"
GEMINI_DIR="$HOME/.gemini"

echo "=== Antigravity 2.0 Summary Store Reload Utility ==="

# 1. Locate archive if needed
if [[ -z "$ARCHIVE_PATH" ]]; then
  for candidate in \
    "$HOME/Downloads/antigravity-mac-migration.tar.gz" \
    "$HOME/Desktop/antigravity-mac-migration.tar.gz" \
    "./antigravity-mac-migration.tar.gz" \
    "$GEMINI_DIR/antigravity/antigravity-sessions.tar.gz"; do
    if [[ -f "$candidate" ]]; then
      ARCHIVE_PATH="$candidate"
      break
    fi
  done
fi

# 2. Force-kill Antigravity and language_server with SIGKILL (-9) so an empty
#    in-memory cache is not flushed over agyhub_summaries_proto.pb on exit.
echo "[1/3] Force-stopping background Antigravity and language_server processes..."
killall -9 Antigravity language_server 2>/dev/null || true
pkill -9 -f "/Applications/Antigravity.app" 2>/dev/null || true
pkill -9 -f "language_server_macos" 2>/dev/null || true
sleep 1

# 3. Restore summary store files from archive if available
if [[ -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]]; then
  echo "[2/3] Restoring conversation_summaries.db and agyhub_summaries_proto.pb from:"
  echo "      $ARCHIVE_PATH"
  tar -xzf "$ARCHIVE_PATH" -C "$GEMINI_DIR" \
    antigravity/conversation_summaries.db \
    antigravity/agyhub_summaries_proto.pb 2>/dev/null || true
else
  echo "[2/3] No archive specified; keeping existing conversation_summaries.db on disk."
fi

# Remove any stale SQLite WAL/SHM lock files
rm -f "$GEMINI_DIR/antigravity/"*.db-shm \
      "$GEMINI_DIR/antigravity/"*.db-wal \
      "$GEMINI_DIR/antigravity/conversations/"*.db-shm \
      "$GEMINI_DIR/antigravity/conversations/"*.db-wal 2>/dev/null || true

if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$GEMINI_DIR/antigravity/conversation_summaries.db" ]]; then
  echo ""
  echo "Conversations per project in conversation_summaries.db:"
  sqlite3 "$GEMINI_DIR/antigravity/conversation_summaries.db" \
    "SELECT COUNT(*), project_id FROM conversation_summaries GROUP BY project_id;" || true
fi

# 4. Relaunch Antigravity
echo ""
echo "[3/3] Launching Antigravity.app..."
if [[ -d "/Applications/Antigravity.app" ]]; then
  open -a "/Applications/Antigravity.app"
fi
echo "Done!"
