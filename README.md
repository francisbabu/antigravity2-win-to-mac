# Antigravity 2.0: Windows to macOS Migration Tool (`antigravity2-win-to-mac`)

Seamlessly migrate your **Google Antigravity 2.0 (AGY 2.0)** workspaces, project conversations, brain artifacts (`task.md`, `implementation_plan.md`, `walkthrough.md`), MCP server configs, custom skills, and folder permissions from **Windows 11** to **macOS**.

---

## Key Features

- **Multi-Drive Windows Path Mapping**: Automatically scans your exported project configurations to detect projects across multiple Windows drives (`C:\Repos`, `D:\Projects`, `E:\Work`, etc.) and prompts you to map each one to its new macOS folder.
- **Interactive & CLI Modes**: Run without arguments for a guided interactive prompt, or pass CLI flags (`--map`, `--archive`, `--non-interactive`) for automated setups.
- **SQLite WAL Safe Export**: Gracefully stops Antigravity on Windows before archiving so SQLite Write-Ahead Logs (`.db-wal`) are fully checkpointed into `.db` files.
- **Binary Protobuf Protection**: Rewrites Windows paths and `file:///` URIs across all JSON configs and Markdown artifacts while keeping binary Protobuf databases (`conversation_summaries.db`, `agyhub_summaries_proto.pb`, `conversations/*.db`) untouched and corruption-free.
- **macOS Background Daemon Handling**: Force-stops the macOS menu-bar `language_server` daemon (`SIGKILL`) before importing so an empty in-memory cache never overwrites your imported conversation summaries.
- **Automatic Backups**: Snapshots your existing `~/.gemini` configuration on macOS to `~/.gemini/backup-YYYYMMDD-HHMMSS` before extracting.
- **MCP Server Configurations**: Migrates `config/mcp_config.json` and remaps all file paths within it (runtime environments like Node/Python packages should be installed on macOS).

---

## Repository Structure

```text
antigravity2-win-to-mac/
├── README.md                        # Quickstart, CLI reference, & troubleshooting
├── LICENSE                          # MIT License
├── windows/
│   └── export-antigravity.ps1       # Windows PowerShell exporter script
├── macos/
│   ├── import-antigravity-mac.sh    # macOS importer & multi-drive path mapper
│   ├── fix-brain-links-mac.sh       # Standalone utility to update file:/// links in brain/*.md
│   └── reload-antigravity-mac.sh    # Troubleshooting utility to force-reload summary DB cache
└── docs/
    └── HOW_IT_WORKS.md              # Technical deep dive into AGY 2.0 SQLite/Protobuf internals
```

---

## Step-by-Step Usage

### Step 1: Export on Windows

> **Important:** Run this from an **external PowerShell or Windows Terminal window** (not inside Antigravity's built-in terminal, because the script closes Antigravity to flush SQLite databases cleanly).

#### Interactive Mode (Recommended)
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\windows\export-antigravity.ps1"
```

#### CLI Mode (With Custom Flags)
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\windows\export-antigravity.ps1" `
  -OutputPath "$HOME\Desktop\antigravity-mac-migration.tar.gz" `
  -Exclude @("custom-plugin-to-exclude") `
  -NonInteractive
```

This creates **`antigravity-mac-migration.tar.gz`** on your Windows Desktop (along with an embedded `migration-manifest.json` listing your detected Windows project roots across all drives).

---

### Step 2: Transfer Archive to Your Mac

Copy `antigravity-mac-migration.tar.gz` to your Mac's `~/Downloads` or `~/Desktop` folder (via USB drive, local network share, cloud drive, or `scp`).

Also make sure your project git repositories are cloned/copied to your Mac (for example, under `~/Developer/projects`).

---

### Step 3: Import on macOS

Open **Terminal** on your Mac and run:

```bash
chmod +x macos/*.sh
./macos/import-antigravity-mac.sh
```

#### Interactive Multi-Drive Flow on macOS
When run without flags, `import-antigravity-mac.sh` will automatically locate your archive, discover every Windows drive/folder where your projects lived, and walk you through mapping them:

```text
==============================================================
   Antigravity 2.0: Windows -> macOS Migration Importer
==============================================================

[1/6] Found archive at '/Users/you/Downloads/antigravity-mac-migration.tar.gz'.
      Press ENTER to use it, or enter another path: 
[2/6] Stopping Antigravity and background language_server processes...
[3/6] Backing up existing config/database files to: /Users/you/.gemini/backup-20261019-143000
[4/6] Extracting archive into /Users/you/.gemini ...
[5/6] Detecting Windows paths from exported configuration...
  Windows User Profile Path [Default: C:\Users\YourName]: 
  macOS User Home Path      [Default: /Users/you]: 

--- Multi-Drive Project Path Mapping ---
Discovered 2 Windows project root directory(s) across your drives:

  [Path 1/2] D:\Projects (8 items: AntigravityTest, WebApp, ...)
    -> Target macOS folder [Default: /Users/you/Developer/projects] (or type 'skip'): /Users/you/Developer/projects

  [Path 2/2] C:\Repos\Work (3 items: ApiService, Billing, ...)
    -> Target macOS folder [Default: /Users/you/Developer/projects] (or type 'skip'): /Users/you/Developer/work

  Add another Windows drive/folder mapping? [y/N]: n

[6/6] Rewriting Windows paths to macOS paths in JSON configuration files...
  + Mapping 'D:\Projects' -> '/Users/you/Developer/projects'
  + Mapping 'C:\Repos\Work' -> '/Users/you/Developer/work'
  + Mapping 'C:\Users\YourName' -> '/Users/you'

Also update clickable file:/// links inside brain/*.md artifacts? [Y/n]: y
  + Updating markdown links in 142 brain artifact files...

  + Verified conversation_summaries.db (28 conversations indexed)

==============================================================
   SUCCESS! Antigravity 2.0 migration to macOS is complete.
==============================================================
  Backup saved at: /Users/you/.gemini/backup-20261019-143000
  Launching Antigravity.app...
```

#### Non-Interactive CLI Mode (Multiple Drives)
You can also pass all mappings directly via repeatable `--map` flags:

```bash
./macos/import-antigravity-mac.sh \
  --archive ~/Downloads/antigravity-mac-migration.tar.gz \
  --win-home 'C:\Users\YourName' \
  --mac-home "$HOME" \
  --map 'D:\Projects=/Users/you/Developer/projects' \
  --map 'C:\Repos\Work=/Users/you/Developer/work' \
  --map 'E:\Experiments=/Users/you/Developer/experiments' \
  --fix-brain-links \
  --non-interactive
```

---

## Companion Utilities & Troubleshooting

### 1. Projects appear in the sidebar on Mac, but conversations inside each project are missing
On macOS, Antigravity keeps a background `language_server` process running in the menu bar tray (`runInBackground = true`). If an older background process was running before migration, it may hold an empty in-memory cache (`resident: 0 -> 0`) or overwrite `agyhub_summaries_proto.pb` when closed normally.

Run the reload utility to force-kill the background daemon (`SIGKILL`), restore `conversation_summaries.db` and `agyhub_summaries_proto.pb` from your archive, and relaunch Antigravity:

```bash
./macos/reload-antigravity-mac.sh ~/Downloads/antigravity-mac-migration.tar.gz
```

### 2. Updating `file:///` links inside Brain Markdown artifacts later
If you skipped updating `brain/*/*.md` links during import or moved a project folder later, run:

```bash
./macos/fix-brain-links-mac.sh \
  --map 'D:\Projects=/Users/you/Developer/projects' \
  --map 'C:\Repos=/Users/you/Developer/repos'
```

### 3. Tip: Running a `.sh` script on macOS without `chmod +x`
You can always run any script directly with `bash`:
```bash
bash macos/import-antigravity-mac.sh
```

---

## How It Works Under the Hood

See [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) for a technical breakdown of Antigravity 2.0's SQLite WAL databases, binary Protobuf summary store, and macOS background daemon behavior.

---

## License

Released under the [MIT License](LICENSE).
