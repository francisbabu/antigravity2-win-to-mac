#Requires -Version 5.1
<#
.SYNOPSIS
    Exports Google Antigravity 2.0 sessions, conversations, brain artifacts,
    project history, MCP configs, skills, and permissions from Windows into a
    portable .tar.gz archive for macOS migration.

.DESCRIPTION
    - Stops Antigravity & language_server cleanly so SQLite WAL (.db-wal) logs flush.
    - Scans ~/.gemini/config/projects/*.json and projects.json to discover all
      unique Windows project root folders across multiple drives (C:\, D:\, E:\, etc.)
      and embeds a migration-manifest.json inside the archive for automatic detection on macOS.
    - Filters out NTFS junctions/reparse points and SQLite lock files (*.db-shm, *.db-wal).

.PARAMETER GeminiRoot
    Path to the Windows .gemini directory. Defaults to "$env:USERPROFILE\.gemini".

.PARAMETER OutputPath
    Destination path for the .tar.gz archive. Defaults to Desktop\antigravity-mac-migration.tar.gz.

.PARAMETER Exclude
    Additional directory or plugin names to exclude from the archive (defaults to none).

.PARAMETER NoKill
    Skip stopping Antigravity and language_server processes.

.PARAMETER NonInteractive
    Run without interactive confirmation prompts.

.EXAMPLE
    .\export-antigravity.ps1

.EXAMPLE
    .\export-antigravity.ps1 -OutputPath "D:\Backups\antigravity-mac-migration.tar.gz" -Exclude @("custom-plugin-to-exclude") -NonInteractive
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GeminiRoot = (Join-Path $env:USERPROFILE ".gemini"),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory = $false)]
    [string[]]$Exclude = @(),

    [Parameter(Mandatory = $false)]
    [switch]$NoKill,

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "   Antigravity 2.0: Windows -> macOS Migration Exporter" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

# Resolve GeminiRoot
if (-not (Test-Path -LiteralPath $GeminiRoot)) {
    if (-not $NonInteractive) {
        $inputRoot = Read-Host "Could not find '$GeminiRoot'. Enter path to your Windows .gemini folder"
        if ($inputRoot) { $GeminiRoot = $inputRoot }
    }
    if (-not (Test-Path -LiteralPath $GeminiRoot)) {
        throw "Antigravity .gemini directory not found at: $GeminiRoot"
    }
}
$GeminiRoot = (Resolve-Path -LiteralPath $GeminiRoot).Path

# Resolve OutputPath
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $desktopDir = [Environment]::GetFolderPath("Desktop")
    if (-not (Test-Path -LiteralPath $desktopDir)) {
        $desktopDir = $PSScriptRoot
    }
    $defaultArchive = Join-Path $desktopDir "antigravity-mac-migration.tar.gz"
    if (-not $NonInteractive) {
        $inputOut = Read-Host "Output archive path [Default: $defaultArchive]"
        $OutputPath = if ([string]::IsNullOrWhiteSpace($inputOut)) { $defaultArchive } else { $inputOut }
    } else {
        $OutputPath = $defaultArchive
    }
}

Write-Host "  Source (.gemini) : $GeminiRoot" -ForegroundColor Gray
Write-Host "  Output Archive   : $OutputPath" -ForegroundColor Gray
if ($Exclude -and $Exclude.Count -gt 0) {
    Write-Host "  Exclusions       : $($Exclude -join ', ')" -ForegroundColor Gray
}
Write-Host ""

# Check if any excluded plugin or path exists; warn if not found
if ($Exclude -and $Exclude.Count -gt 0) {
    $searchDirs = @(
        (Join-Path $GeminiRoot "config\plugins"),
        (Join-Path $GeminiRoot "antigravity\skills"),
        (Join-Path $GeminiRoot "antigravity\plugin_data")
    )
    foreach ($ex in $Exclude) {
        if ([string]::IsNullOrWhiteSpace($ex)) { continue }
        $found = $false
        foreach ($dir in $searchDirs) {
            if (Test-Path -LiteralPath $dir) {
                $matched = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -like "$ex*"
                }
                if ($matched) {
                    $found = $true
                    break
                }
            }
        }
        if (-not $found) {
            $rootDirect = Join-Path $GeminiRoot ($ex -replace '/', '\')
            if (Test-Path -LiteralPath $rootDirect) {
                $found = $true
            }
        }
        if (-not $found) {
            Write-Warning "Plugin or path '$ex' specified in -Exclude was not found in '$GeminiRoot'. Continuing execution..."
        }
    }
}

# ---------------------------------------------------------------------------
# Step 1: Stop Antigravity and language_server cleanly to flush SQLite WAL
# ---------------------------------------------------------------------------
if (-not $NoKill) {
    $runningProcs = Get-Process -Name "Antigravity", "language_server" -ErrorAction SilentlyContinue
    if ($runningProcs) {
        $shouldStop = $true
        if (-not $NonInteractive) {
            $ans = Read-Host "[1/4] Antigravity is currently running. Stop it now to flush SQLite databases cleanly? [Y/n]"
            if ($ans -match '^[Nn]') {
                $shouldStop = $false
                Write-Warning "Exporting while Antigravity is running may omit recent uncheckpointed SQLite WAL data."
            }
        }
        if ($shouldStop) {
            Write-Host "[1/4] Stopping Antigravity and language_server processes to flush SQLite databases..." -ForegroundColor Yellow
            Stop-Process -Name "Antigravity" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Stop-Process -Name "Antigravity", "language_server" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Write-Host "  + Antigravity stopped cleanly." -ForegroundColor Green
        }
    } else {
        Write-Host "[1/4] Antigravity is already closed." -ForegroundColor Gray
    }
} else {
    Write-Host "[1/4] Skipping process termination (-NoKill specified)." -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Step 2: Discover project roots across all Windows drives for manifest
# ---------------------------------------------------------------------------
Write-Host "[2/4] Scanning project configurations for multi-drive paths..." -ForegroundColor Cyan
$discoveredProjectPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$discoveredParentRoots  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

$projectFiles = @()
$configProjectsDir = Join-Path $GeminiRoot "config\projects"
if (Test-Path -LiteralPath $configProjectsDir) {
    $projectFiles += Get-ChildItem -LiteralPath $configProjectsDir -Filter "*.json" -File -ErrorAction SilentlyContinue
}
$rootProjectsJson = Join-Path $GeminiRoot "projects.json"
if (Test-Path -LiteralPath $rootProjectsJson) {
    $projectFiles += Get-Item -LiteralPath $rootProjectsJson
}

$winPathRegex = [regex]'([a-zA-Z]:\\(?:[^\\/:*?"<>|\r\n]+\\)*[^\\/:*?"<>|\r\n]+|[a-zA-Z]:/(?:[^\\/:*?"<>|\r\n]+/)*[^\\/:*?"<>|\r\n]+)'

foreach ($file in $projectFiles) {
    try {
        $raw = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        # Unescape double backslashes from JSON
        $unescaped = $raw -replace '\\\\', '\'
        foreach ($match in $winPathRegex.Matches($unescaped)) {
            $candidate = ($match.Value -replace '/', '\').TrimEnd('\')
            # Skip internal .gemini paths
            if ($candidate.StartsWith($GeminiRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($candidate -match '^[a-zA-Z]:\\Users\\[^\\]+$') { continue }
            [void]$discoveredProjectPaths.Add($candidate)
            $parentDir = Split-Path -Path $candidate -Parent
            if ($parentDir -and ($parentDir -notmatch '^[a-zA-Z]:\\$')) {
                [void]$discoveredParentRoots.Add($parentDir)
            } elseif ($parentDir -match '^[a-zA-Z]:\\$') {
                [void]$discoveredParentRoots.Add($candidate)
            }
        }
    } catch {
        # Ignore malformed JSON files
    }
}

foreach ($root in ($discoveredParentRoots | Sort-Object)) {
    Write-Host "  + Discovered Windows project root: $root" -ForegroundColor Gray
}

# Write temporary migration-manifest.json into $GeminiRoot so tar includes it
$manifestPath = Join-Path $GeminiRoot "migration-manifest.json"
$manifestData = [ordered]@{
    schemaVersion       = 1
    exportedAtUtc       = (Get-Date).ToUniversalTime().ToString("o")
    windowsUserProfile  = $env:USERPROFILE
    windowsUserName     = $env:USERNAME
    projectParentRoots  = @($discoveredParentRoots | Sort-Object)
    projectPaths        = @($discoveredProjectPaths | Sort-Object)
}
$manifestData | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

# ---------------------------------------------------------------------------
# Step 3: Collect existing relative paths under ~/.gemini
# ---------------------------------------------------------------------------
$candidatePaths = @(
    "migration-manifest.json",
    "antigravity/conversations",
    "antigravity/brain",
    "antigravity/annotations",
    "antigravity/knowledge",
    "antigravity/plugin_data",
    "antigravity/conversation_summaries.db",
    "antigravity/agyhub_summaries_proto.pb",
    "config/config.json",
    "config/mcp_config.json",
    "config/projects",
    "config/plugins",
    "projects.json",
    "trustedFolders.json"
)

# Add non-junction skill directories inside antigravity/skills
$skillsDir = Join-Path $GeminiRoot "antigravity\skills"
if (Test-Path -LiteralPath $skillsDir) {
    Get-ChildItem -LiteralPath $skillsDir -Force | Where-Object {
        $isReparse = [bool]($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        $isExcluded = $false
        foreach ($ex in $Exclude) {
            if ($_.Name -like "$ex*") { $isExcluded = $true; break }
        }
        (-not $isReparse) -and (-not $isExcluded)
    } | ForEach-Object {
        $candidatePaths += "antigravity/skills/$($_.Name)"
    }
}

$itemsToArchive = @()
Write-Host "[3/4] Collecting items to export from $GeminiRoot..." -ForegroundColor Cyan
foreach ($relPath in $candidatePaths) {
    $fullPath = Join-Path $GeminiRoot ($relPath -replace '/', '\')
    if (Test-Path -LiteralPath $fullPath) {
        $itemsToArchive += $relPath
        Write-Host "  + $relPath" -ForegroundColor Gray
    }
}

if ($itemsToArchive.Count -le 1) {
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    throw "No Antigravity session data found in $GeminiRoot"
}

# ---------------------------------------------------------------------------
# Step 4: Create compressed .tar.gz archive
# ---------------------------------------------------------------------------
Write-Host "[4/4] Creating compressed archive at: $OutputPath ..." -ForegroundColor Cyan
$outputDir = Split-Path -Path $OutputPath -Parent
if ($outputDir -and (-not (Test-Path -LiteralPath $outputDir))) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
if (Test-Path -LiteralPath $OutputPath) {
    Remove-Item -LiteralPath $OutputPath -Force
}

$tarArgs = @(
    "-czf", $OutputPath,
    "--exclude=node_modules",
    "--exclude=.pnpm",
    "--exclude=*.db-shm",
    "--exclude=*.db-wal"
)
foreach ($ex in $Exclude) {
    if (-not [string]::IsNullOrWhiteSpace($ex)) {
        $tarArgs += "--exclude=$ex"
    }
}
$tarArgs += @("-C", $GeminiRoot) + $itemsToArchive

try {
    & "$env:SystemRoot\System32\tar.exe" @tarArgs
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe failed with exit code $LASTEXITCODE"
    }
} finally {
    # Always clean up the temporary manifest file from the live Windows .gemini folder
    if (Test-Path -LiteralPath $manifestPath) {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
}

$sizeMB = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1MB, 2)
Write-Host ""
Write-Host "SUCCESS! Migration archive created ($sizeMB MB):" -ForegroundColor Green
Write-Host "  $OutputPath" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next step: Copy this file to your Mac and run:" -ForegroundColor Cyan
Write-Host "  ./macos/import-antigravity-mac.sh" -ForegroundColor White
Write-Host ""
