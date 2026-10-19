#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0: Standalone Brain Artifact Link Updater (macOS)
# ==============================================================================
# Rewrites Windows file:/// links inside ~/.gemini/antigravity/brain/*/*.md
# across one or more Windows drive/folder mappings without touching binary DBs.
# ==============================================================================

set -euo pipefail

BRAIN_DIR="$HOME/.gemini/antigravity/brain"
declare -a MAP_WIN_PATHS=()
declare -a MAP_MAC_PATHS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--map "WinPath=MacPath" ...]

Examples:
  $(basename "$0") --map 'D:\Projects=/Users/you/Developer/projects' --map 'C:\Repos=/Users/you/Developer/repos'
  $(basename "$0")   # Runs interactively
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)
      if [[ "$2" != *"="* ]]; then
        echo "ERROR: --map must be in 'WinPath=MacPath' format (got: $2)" >&2
        exit 1
      fi
      MAP_WIN_PATHS+=("${2%%=*}")
      MAP_MAC_PATHS+=("${2#*=}")
      shift 2
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

if [[ ! -d "$BRAIN_DIR" ]]; then
  echo "No brain directory found at: $BRAIN_DIR"
  exit 0
fi

if [[ ${#MAP_WIN_PATHS[@]} -eq 0 ]]; then
  echo "=== Antigravity 2.0 Brain Markdown Link Updater ==="
  while true; do
    read -r -p "Enter Windows path to replace (e.g. D:\Projects) [press ENTER when done]: " win_in
    [[ -z "$win_in" ]] && break
    win_clean=$(printf '%s' "$win_in" | sed 's|/|\\|g; s|\\\\|\\|g; s|\\$||')
    default_mac="$HOME/Developer/projects"
    read -r -p "Enter target macOS path [Default: $default_mac]: " mac_in
    mac_clean="${mac_in:-$default_mac}"
    mac_clean="${mac_clean/#\~/$HOME}"
    mac_clean="${mac_clean%/}"
    MAP_WIN_PATHS+=("$win_clean")
    MAP_MAC_PATHS+=("$mac_clean")
  done
fi

if [[ ${#MAP_WIN_PATHS[@]} -eq 0 ]]; then
  echo "No mappings specified. Exiting."
  exit 0
fi

BRAIN_FILES=()
while IFS= read -r -d '' bf; do
  BRAIN_FILES+=("$bf")
done < <(find "$BRAIN_DIR" -type f -name "*.md" -print0 2>/dev/null || true)

if [[ ${#BRAIN_FILES[@]} -eq 0 ]]; then
  echo "No .md files found inside $BRAIN_DIR"
  exit 0
fi

echo "Updating ${#BRAIN_FILES[@]} markdown files in $BRAIN_DIR ..."

for i in "${!MAP_WIN_PATHS[@]}"; do
  w_path="${MAP_WIN_PATHS[$i]}"
  m_path="${MAP_MAC_PATHS[$i]/#\~/$HOME}"
  m_path="${m_path%/}"
  echo "  + Mapping '$w_path' -> '$m_path'"

  /usr/bin/perl -pi -e '
    BEGIN {
      $win = shift @ARGV;
      $mac = shift @ARGV;
      ($drive, $rest) = $win =~ /^([a-zA-Z]):\\?(.*)$/;
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
    s{$pat_uri((?:\\\\|\\|\/)[^\s"<>|\)\r\n]*)?}{
      my $tail = $1 // "";
      $tail =~ s{\\\\}{/}g;
      $tail =~ s{\\}{/}g;
      "file://$mac$tail"
    }ge;
    s{$pat_plain((?:\\\\|\\|\/)[^\s"<>|\)\r\n]*)?}{
      my $tail = $1 // "";
      $tail =~ s{\\\\}{/}g;
      $tail =~ s{\\}{/}g;
      "$mac$tail"
    }ge;
  ' "$w_path" "$m_path" "${BRAIN_FILES[@]}"
done

echo "Done! All brain artifact markdown links have been updated."
