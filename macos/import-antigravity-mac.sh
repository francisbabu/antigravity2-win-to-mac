#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0: Windows -> macOS Migration Importer
# ==============================================================================
# Safely imports an Antigravity 2.0 migration archive (.tar.gz) onto macOS,
# maps Windows project directories across multiple drives (C:\, D:\, E:\, etc.)
# to macOS directories, protects binary Protobuf/SQLite databases, and restarts
# Antigravity cleanly.
# ==============================================================================

set -euo pipefail

ARCHIVE_PATH=""
WIN_HOME=""
MAC_HOME="$HOME"
GEMINI_DIR="$HOME/.gemini"
FIX_BRAIN_LINKS=""
NO_LAUNCH=0
NON_INTERACTIVE=0

declare -a CLI_WIN_PATHS=()
declare -a CLI_MAC_PATHS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -a, --archive <path>          Path to antigravity-mac-migration.tar.gz
  -w, --win-home <path>         Windows user profile path (e.g. 'C:\Users\YourName')
  -m, --mac-home <path>         macOS home directory (default: $HOME)
      --map "<Win>=<Mac>"       Map a Windows project root to a macOS folder.
                                Can be specified multiple times for multiple drives:
                                  --map 'D:\Projects=$HOME/Developer/projects'
                                  --map 'C:\Repos=$HOME/Developer/repos'
      --fix-brain-links         Also rewrite file:/// links inside brain/*/*.md
      --no-fix-brain-links      Skip rewriting links inside brain/*/*.md
      --no-launch               Do not launch Antigravity.app after import
  -y, --non-interactive         Run without interactive prompts
  -h, --help                    Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--archive)
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    -w|--win-home)
      WIN_HOME="$2"
      shift 2
      ;;
    -m|--mac-home)
      MAC_HOME="${2%/}"
      shift 2
      ;;
    --map)
      if [[ "$2" != *"="* ]]; then
        echo "ERROR: --map argument must be in the format 'WinPath=MacPath' (got: $2)" >&2
        exit 1
      fi
      CLI_WIN_PATHS+=("${2%%=*}")
      CLI_MAC_PATHS+=("${2#*=}")
      shift 2
      ;;
    --fix-brain-links)
      FIX_BRAIN_LINKS="yes"
      shift
      ;;
    --no-fix-brain-links)
      FIX_BRAIN_LINKS="no"
      shift
      ;;
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    -y|--non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

echo ""
echo "=============================================================="
echo "   Antigravity 2.0: Windows -> macOS Migration Importer"
echo "=============================================================="
echo ""

# ------------------------------------------------------------------------------
# 1. Locate the migration archive
# ------------------------------------------------------------------------------
if [[ -z "$ARCHIVE_PATH" ]]; then
  for candidate in \
    "$HOME/Downloads/antigravity-mac-migration.tar.gz" \
    "$HOME/Desktop/antigravity-mac-migration.tar.gz" \
    "./antigravity-mac-migration.tar.gz" \
    "$HOME/Downloads/antigravity-sessions.tar.gz" \
    "$HOME/Desktop/antigravity-sessions.tar.gz"; do
    if [[ -f "$candidate" ]]; then
      ARCHIVE_PATH="$candidate"
      break
    fi
  done
fi

if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  if [[ -n "$ARCHIVE_PATH" ]]; then
    read -r -p "[1/6] Found archive at '$ARCHIVE_PATH'. Press ENTER to use it, or enter another path: " input_archive
    if [[ -n "$input_archive" ]]; then
      ARCHIVE_PATH="${input_archive/#\~/$HOME}"
    fi
  else
    read -r -p "[1/6] Enter path to antigravity-mac-migration.tar.gz: " input_archive
    ARCHIVE_PATH="${input_archive/#\~/$HOME}"
  fi
fi

if [[ -z "$ARCHIVE_PATH" || ! -f "$ARCHIVE_PATH" ]]; then
  echo "ERROR: Migration archive not found at: ${ARCHIVE_PATH:-<empty>}" >&2
  exit 1
fi
echo "  + Using archive: $ARCHIVE_PATH"

# ------------------------------------------------------------------------------
# 2. Force-kill Antigravity & language_server (macOS background tray daemon)
# ------------------------------------------------------------------------------
echo "[2/6] Stopping Antigravity and background language_server processes..."
killall -9 Antigravity language_server 2>/dev/null || true
pkill -9 -f "/Applications/Antigravity.app" 2>/dev/null || true
pkill -9 -f "language_server_macos" 2>/dev/null || true
sleep 1

# ------------------------------------------------------------------------------
# 3. Backup existing ~/.gemini files before extracting
# ------------------------------------------------------------------------------
mkdir -p "$GEMINI_DIR"
BACKUP_DIR="$GEMINI_DIR/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "[3/6] Backing up existing config/database files to: $BACKUP_DIR"

for item in \
  "antigravity/conversation_summaries.db" \
  "antigravity/agyhub_summaries_proto.pb" \
  "config" \
  "projects.json" \
  "trustedFolders.json"; do
  if [[ -e "$GEMINI_DIR/$item" ]]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$item")"
    cp -R "$GEMINI_DIR/$item" "$BACKUP_DIR/$item" 2>/dev/null || true
  fi
done

# ------------------------------------------------------------------------------
# 4. Extract archive and clean SQLite WAL/SHM lock files
# ------------------------------------------------------------------------------
echo "[4/6] Extracting archive into $GEMINI_DIR ..."
tar -xzf "$ARCHIVE_PATH" -C "$GEMINI_DIR"

rm -f "$GEMINI_DIR/antigravity/"*.db-shm \
      "$GEMINI_DIR/antigravity/"*.db-wal \
      "$GEMINI_DIR/antigravity/conversations/"*.db-shm \
      "$GEMINI_DIR/antigravity/conversations/"*.db-wal 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. Discover Windows Home & Multi-Drive Project Roots
# ------------------------------------------------------------------------------
echo "[5/6] Detecting Windows paths from exported configuration..."

MANIFEST_FILE="$GEMINI_DIR/migration-manifest.json"

# Auto-detect Windows Home directory (e.g. C:\Users\YourName)
if [[ -z "$WIN_HOME" ]]; then
  WIN_HOME=$(/usr/bin/perl -ne '
    while (/([a-zA-Z]:\\+Users\\+[^\\\/"\r\n]+|[a-zA-Z]:\/+Users\/+[^\\\/"\r\n]+)/g) {
      my $p = $1;
      $p =~ s{[\/\\]+}{\\}g;
      print "$p\n";
      exit 0;
    }
  ' "$MANIFEST_FILE" "$GEMINI_DIR/config/mcp_config.json" "$GEMINI_DIR/trustedFolders.json" "$GEMINI_DIR/projects.json" 2>/dev/null | head -n 1 || true)
fi

if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
  read -r -p "  Windows User Profile Path [Default: ${WIN_HOME:-C:\Users\YourName}]: " input_win_home
  WIN_HOME="${input_win_home:-${WIN_HOME:-C:\Users\YourName}}"
  read -r -p "  macOS User Home Path      [Default: $MAC_HOME]: " input_mac_home
  MAC_HOME="${input_mac_home:-$MAC_HOME}"
  MAC_HOME="${MAC_HOME/#\~/$HOME}"
  MAC_HOME="${MAC_HOME%/}"
fi

# Normalize WIN_HOME to single backslashes without trailing slash (e.g. C:\Users\Name)
WIN_HOME=$(printf '%s' "$WIN_HOME" | sed 's|/|\\|g; s|\\\\|\\|g; s|\\$||')

declare -a MAP_WIN_PATHS=()
declare -a MAP_MAC_PATHS=()

if [[ ${#CLI_WIN_PATHS[@]} -gt 0 ]]; then
  for i in "${!CLI_WIN_PATHS[@]}"; do
    w_clean=$(printf '%s' "${CLI_WIN_PATHS[$i]}" | sed 's|/|\\|g; s|\\\\|\\|g; s|\\$||')
    m_clean="${CLI_MAC_PATHS[$i]/#\~/$HOME}"
    m_clean="${m_clean%/}"
    MAP_WIN_PATHS+=("$w_clean")
    MAP_MAC_PATHS+=("$m_clean")
  done
else
  # Auto-discover all unique Windows parent project directories across all drives
  DISCOVERED_ROOTS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && DISCOVERED_ROOTS+=("$line")
  done < <(/usr/bin/perl -e '
    use strict;
    use warnings;
    my $win_home = lc($ARGV[0] // "");
    my %roots;
    my %samples;
    for my $f (@ARGV[1..$#ARGV]) {
      next unless -f $f;
      open my $fh, "<", $f or next;
      local $/;
      my $content = <$fh>;
      close $fh;
      $content =~ s/\\\\/\\/g;
      $content =~ s{file:///([a-zA-Z])%3[aA]/}{$1:\\}g;
      $content =~ s{file:///([a-zA-Z]):/}{$1:\\}g;
      while ($content =~ /([a-zA-Z]:[\\\/](?:[^\\\/:*?"<>|\r\n]+[\\\/])+[^\\\/:*?"<>|\r\n]+)/g) {
        my $p = $1;
        $p =~ s{[\/\\]+}{\\}g;
        $p =~ s{\\+$}{};
        next if $p =~ /\\\.gemini(\\|$)/i;
        next if $p =~ /\\AppData\\/i;
        next if $win_home ne "" && lc($p) eq $win_home;
        if ($p =~ /^([a-zA-Z]:\\.+?)\\([^\\]+)$/) {
          my ($parent, $leaf) = ($1, $2);
          next if $win_home ne "" && lc($parent) eq $win_home;
          # Skip if parent looks like inside a repo subfolder when its parent is already known
          $roots{ucfirst($parent)}++;
          $samples{ucfirst($parent)}{$leaf} = 1;
        }
      }
    }
    # Filter out child paths whose parent is also in %roots
    my @sorted = sort keys %roots;
    for my $r (@sorted) {
      my $is_child = 0;
      for my $other (@sorted) {
        next if lc($r) eq lc($other);
        if (index(lc($r), lc($other) . "\\") == 0) {
          $is_child = 1;
          last;
        }
      }
      if (!$is_child) {
        my @proj_names = sort keys %{$samples{$r}};
        my $preview = join(", ", @proj_names[0 .. ($#proj_names > 2 ? 2 : $#proj_names)]);
        $preview .= ", ..." if scalar(@proj_names) > 3;
        print "$r\t" . scalar(@proj_names) . "\t$preview\n";
      }
    }
  ' "$WIN_HOME" \
    "$GEMINI_DIR/projects.json" \
    "$GEMINI_DIR/trustedFolders.json" \
    "$GEMINI_DIR/config/projects/"*.json 2>/dev/null || true)

  if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
    echo ""
    echo "--- Multi-Drive Project Path Mapping ---"
    if [[ ${#DISCOVERED_ROOTS[@]} -gt 0 ]]; then
      echo "Discovered ${#DISCOVERED_ROOTS[@]} Windows project root directory(s) across your drives:"
      idx=1
      for entry in "${DISCOVERED_ROOTS[@]}"; do
        win_root=$(printf '%s' "$entry" | cut -f1)
        proj_count=$(printf '%s' "$entry" | cut -f2)
        proj_preview=$(printf '%s' "$entry" | cut -f3)
        echo ""
        echo "  [Path $idx/${#DISCOVERED_ROOTS[@]}] $win_root ($proj_count items: $proj_preview)"
        default_mac="$MAC_HOME/Developer/projects"
        read -r -p "    -> Target macOS folder [Default: $default_mac] (or type 'skip'): " mac_target
        if [[ "$mac_target" != "skip" ]]; then
          mac_target="${mac_target:-$default_mac}"
          mac_target="${mac_target/#\~/$HOME}"
          mac_target="${mac_target%/}"
          MAP_WIN_PATHS+=("$win_root")
          MAP_MAC_PATHS+=("$mac_target")
        fi
        idx=$((idx + 1))
      done
    else
      echo "No Windows project paths were automatically detected in config files."
      read -r -p "  Enter a Windows Projects folder to map (e.g. D:\Projects) [or press ENTER to skip]: " custom_win
      if [[ -n "$custom_win" ]]; then
        custom_win=$(printf '%s' "$custom_win" | sed 's|/|\\|g; s|\\\\|\\|g; s|\\$||')
        default_mac="$MAC_HOME/Developer/projects"
        read -r -p "  Enter target macOS folder [Default: $default_mac]: " custom_mac
        custom_mac="${custom_mac:-$default_mac}"
        custom_mac="${custom_mac/#\~/$HOME}"
        custom_mac="${custom_mac%/}"
        MAP_WIN_PATHS+=("$custom_win")
        MAP_MAC_PATHS+=("$custom_mac")
      fi
    fi

    # Allow user to add additional drive/folder mappings interactively
    while true; do
      echo ""
      read -r -p "  Add another Windows drive/folder mapping? [y/N]: " more_map
      if [[ ! "$more_map" =~ ^[Yy] ]]; then
        break
      fi
      read -r -p "    Windows folder path (e.g. E:\Work or C:\Repos): " extra_win
      [[ -z "$extra_win" ]] && break
      extra_win=$(printf '%s' "$extra_win" | sed 's|/|\\|g; s|\\\\|\\|g; s|\\$||')
      read -r -p "    Target macOS folder (e.g. $MAC_HOME/Developer/work): " extra_mac
      [[ -z "$extra_mac" ]] && break
      extra_mac="${extra_mac/#\~/$HOME}"
      extra_mac="${extra_mac%/}"
      MAP_WIN_PATHS+=("$extra_win")
      MAP_MAC_PATHS+=("$extra_mac")
    done
  else
    # Non-interactive fallback: map all discovered roots to $MAC_HOME/Developer/projects
    for entry in "${DISCOVERED_ROOTS[@]}"; do
      win_root=$(printf '%s' "$entry" | cut -f1)
      MAP_WIN_PATHS+=("$win_root")
      MAP_MAC_PATHS+=("$MAC_HOME/Developer/projects")
    done
  fi
fi

# Always append WIN_HOME -> MAC_HOME as the final fallback mapping
if [[ -n "$WIN_HOME" ]]; then
  MAP_WIN_PATHS+=("$WIN_HOME")
  MAP_MAC_PATHS+=("$MAC_HOME")
fi

# ------------------------------------------------------------------------------
# 6. Rewrite paths in JSON config files (Never touch binary .db / .pb files!)
# ------------------------------------------------------------------------------
echo ""
echo "[6/6] Rewriting Windows paths to macOS paths in JSON configuration files..."

apply_path_mappings_to_files() {
  local target_Win="$1"
  local target_Mac="$2"
  shift 2
  local files=("$@")
  [[ ${#files[@]} -eq 0 ]] && return 0

  /usr/bin/perl -pi -e '
    BEGIN {
      $win = shift @ARGV;
      $mac = shift @ARGV;
      # Split drive letter and rest of path
      ($drive, $rest) = $win =~ /^([a-zA-Z]):\\?(.*)$/;
      # Build regex matching single/double backslashes or forward slashes
      my @parts = grep { length($_) > 0 } split(/[\\\/]+/, $rest);
      my $sep = q{(?:\\\\|\\|\/)};
      my $body = join($sep, map { quotemeta($_) } @parts);
      $pat_plain = defined($drive)
        ? (length($body) ? qr/(?i:\Q$drive\E:(?:$sep)$body)/ : qr/(?i:\Q$drive\E:)/)
        : qr/\Q$win\E/i;
      $pat_uri = defined($drive)
        ? (length($body) ? qr/(?i:file:\/\/\/\Q$drive\E(?::|%3a)(?:\/|\\|\\\\)$body)/ : qr/(?i:file:\/\/\/\Q$drive\E(?::|%3a))/)
        : qr/file:\/\/\/\Q$win\E/i;
    }
    # 1. Replace file:/// URIs and normalize trailing backslashes on same URI
    s{$pat_uri((?:\\\\|\\|\/)[^\s"<>|\)\r\n]*)?}{
      my $tail = $1 // "";
      $tail =~ s{\\\\}{/}g;
      $tail =~ s{\\}{/}g;
      "file://$mac$tail"
    }ge;
    # 2. Replace plain/JSON paths and normalize trailing backslashes inside the path
    s{$pat_plain((?:\\\\|\\|\/)[^\s"<>|\)\r\n]*)?}{
      my $tail = $1 // "";
      $tail =~ s{\\\\}{/}g;
      $tail =~ s{\\}{/}g;
      "$mac$tail"
    }ge;
  ' "$target_Win" "$target_Mac" "${files[@]}"
}

CONFIG_FILES=()
while IFS= read -r -d '' f; do
  CONFIG_FILES+=("$f")
done < <(find "$GEMINI_DIR/config" "$GEMINI_DIR/projects.json" "$GEMINI_DIR/trustedFolders.json" -type f -name "*.json" -print0 2>/dev/null || true)

if [[ ${#CONFIG_FILES[@]} -gt 0 ]]; then
  for i in "${!MAP_WIN_PATHS[@]}"; do
    echo "  + Mapping '${MAP_WIN_PATHS[$i]}' -> '${MAP_MAC_PATHS[$i]}'"
    apply_path_mappings_to_files "${MAP_WIN_PATHS[$i]}" "${MAP_MAC_PATHS[$i]}" "${CONFIG_FILES[@]}"
  done
fi

# Optional: Also update file:/// markdown links inside brain/*/*.md
if [[ -z "$FIX_BRAIN_LINKS" && "$NON_INTERACTIVE" -eq 0 ]]; then
  echo ""
  read -r -p "Also update clickable file:/// links inside brain/*.md artifacts? [Y/n]: " ans_brain
  if [[ "$ans_brain" =~ ^[Nn] ]]; then
    FIX_BRAIN_LINKS="no"
  else
    FIX_BRAIN_LINKS="yes"
  fi
fi

if [[ "$FIX_BRAIN_LINKS" == "yes" && -d "$GEMINI_DIR/antigravity/brain" ]]; then
  BRAIN_FILES=()
  while IFS= read -r -d '' bf; do
    BRAIN_FILES+=("$bf")
  done < <(find "$GEMINI_DIR/antigravity/brain" -type f -name "*.md" -print0 2>/dev/null || true)

  if [[ ${#BRAIN_FILES[@]} -gt 0 ]]; then
    echo "  + Updating markdown links in ${#BRAIN_FILES[@]} brain artifact files..."
    for i in "${!MAP_WIN_PATHS[@]}"; do
      apply_path_mappings_to_files "${MAP_WIN_PATHS[$i]}" "${MAP_MAC_PATHS[$i]}" "${BRAIN_FILES[@]}"
    done
  fi
fi

# Clean up temporary migration-manifest.json
rm -f "$MANIFEST_FILE" 2>/dev/null || true

# Verify summary database count if sqlite3 is available
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$GEMINI_DIR/antigravity/conversation_summaries.db" ]]; then
  SUMMARY_COUNT=$(sqlite3 "$GEMINI_DIR/antigravity/conversation_summaries.db" "SELECT COUNT(*) FROM conversation_summaries;" 2>/dev/null || echo "unknown")
  echo ""
  echo "  + Verified conversation_summaries.db ($SUMMARY_COUNT conversations indexed)"
fi

echo ""
echo "=============================================================="
echo "   SUCCESS! Antigravity 2.0 migration to macOS is complete."
echo "=============================================================="
echo "  Backup saved at: $BACKUP_DIR"

if [[ "$NO_LAUNCH" -eq 0 && -d "/Applications/Antigravity.app" ]]; then
  echo "  Launching Antigravity.app..."
  open -a "/Applications/Antigravity.app"
fi
echo ""
