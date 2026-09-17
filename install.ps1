# Installs Northpane Bridge for the current user on Windows. No administrator rights.
#
#   irm https://github.com/SantEnnio/northpane-bridge/releases/latest/download/install.ps1 | iex
#
# The Northpane app runs the same script over SSH with everything pinned by the app itself:
#
#   & install.ps1 -Version 1.0.0 -Sha256 <hex> [-Url https://...] [-File <path already on the Host>]
#
# Layout (shared with earlier Northpane installs):
#   %LOCALAPPDATA%\Northpane\Bridge\versions\<version>\northpane-bridge.exe
#   %LOCALAPPDATA%\Northpane\Bridge\current-version.txt, previous-version.txt
#   %USERPROFILE%\.local\bin\northpane-bridge.exe   (a copy; added to the user PATH)
#
# Machine-readable lines on stdout start with "northpane-install ". Exit codes match install.sh:
#   2 usage, 21 download failed, 22 digest mismatch, 23 self-check failed, 24 unsupported platform
param(
    [string]$Version = "",
    [string]$Sha256 = "",
    [string]$Url = "",
    [string]$File = ""
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repository = "SantEnnio/northpane-bridge"

function Say([string]$line) { [Console]::Out.WriteLine("northpane-install $line") }
function Fail([int]$code, [string]$message) { [Console]::Error.WriteLine("northpane-install: $message"); exit $code }

switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { $platform = "windows-x86_64" }
    "ARM64" { $platform = "windows-arm64" }
    default { Fail 24 "unsupported architecture $($env:PROCESSOR_ARCHITECTURE)" }
}
Say "platform=$platform"

if ($Version -and $Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { Fail 2 "invalid version" }
if ($Sha256 -and $Sha256 -notmatch '^[0-9a-f]{64}$') { Fail 2 "the digest must be 64 lowercase hex characters" }
if ($Url -and -not $Url.StartsWith("https://")) { Fail 2 "the download URL must use HTTPS" }

$asset = "northpane-bridge-$platform.zip"
$work = Join-Path ([IO.Path]::GetTempPath()) ("northpane-install-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $work | Out-Null
try {
    function Fetch([string]$from, [string]$to) {
        try { Invoke-WebRequest -UseBasicParsing -Uri $from -OutFile $to } catch { Fail 21 "download failed: $from" }
    }

    if (-not $Version) {
        if ($File) { Fail 2 "-File needs -Version and -Sha256" }
        $base = "https://github.com/$repository/releases/latest/download"
        Fetch "$base/SHA256SUMS" (Join-Path $work "SHA256SUMS")
        Fetch "$base/VERSION" (Join-Path $work "VERSION")
        $Version = (Get-Content -Raw (Join-Path $work "VERSION")).Trim()
        if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { Fail 21 "the release names no valid version" }
        foreach ($line in Get-Content (Join-Path $work "SHA256SUMS")) {
            $parts = $line -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $asset) { $Sha256 = $parts[0] }
        }
        if (-not $Sha256) { Fail 24 "the latest release has no Bridge for $platform" }
    }
    if (-not $Sha256) { Fail 2 "-Version needs -Sha256" }
    if (-not $Url) { $Url = "https://github.com/$repository/releases/download/v$Version/$asset" }

    $archive = Join-Path $work $asset
    if ($File) {
        if (-not (Test-Path $File)) { Fail 21 "no file at $File" }
        Move-Item -Force $File $archive
    } else {
        Fetch $Url $archive
    }
    $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) { Fail 22 "digest mismatch: expected $Sha256, got $actual" }

    $root = Join-Path $env:LOCALAPPDATA "Northpane\Bridge"
    $target = Join-Path $root "versions\$Version"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Expand-Archive -Force -Path $archive -DestinationPath (Join-Path $work "unpacked")
    Copy-Item -Force (Join-Path $work "unpacked\northpane-bridge.exe") (Join-Path $target "northpane-bridge.exe")
    & (Join-Path $target "northpane-bridge.exe") self-check --json | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 23 "the downloaded Bridge failed its self-check" }

    $currentFile = Join-Path $root "current-version.txt"
    $previous = "none"
    if (Test-Path $currentFile) { $previous = (Get-Content -Raw $currentFile).Trim() }
    if ($previous -ne "none" -and $previous -ne $Version) { Set-Content -NoNewline (Join-Path $root "previous-version.txt") $previous }
    $bin = Join-Path $HOME ".local\bin"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Copy-Item -Force (Join-Path $target "northpane-bridge.exe") (Join-Path $bin "northpane-bridge.exe")
    Set-Content -NoNewline $currentFile $Version
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (($userPath -split ';') -notcontains $bin) {
        [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(';') + ';' + $bin).Trim(';')), "User")
    }
    Say "previous=$previous"
    Say "activated=$Version"

    # Keep the active version and the one before it, so the app can still roll back.
    $keep = @($Version)
    $previousFile = Join-Path $root "previous-version.txt"
    if (Test-Path $previousFile) { $keep += (Get-Content -Raw $previousFile).Trim() }
    Get-ChildItem -Directory (Join-Path $root "versions") | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Recurse -Force
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
