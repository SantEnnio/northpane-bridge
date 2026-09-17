# Installs Northpane Bridge for the current user on Windows. No administrator rights.
#
#   irm https://github.com/SantEnnio/northpane-bridge/releases/latest/download/install.ps1 | iex
#
# The Northpane app runs the same script over SSH with everything pinned by the app itself:
#
#   & install.ps1 -Version 1.0.0 -Sha256 <hex> [-Url https://...] [-File <path already on the Host>]
#
# Layout:
#   %LOCALAPPDATA%\Northpane\Bridge\versions\<version>\   northpane-bridge.exe and the DLLs it needs
#   %LOCALAPPDATA%\Northpane\Bridge\current               junction to the active version, on the user PATH
#   %LOCALAPPDATA%\Northpane\Bridge\current-version.txt, previous-version.txt
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
    $versions = Join-Path $root "versions"
    $target = Join-Path $versions $Version
    $unpacked = Join-Path $work "unpacked"
    Expand-Archive -Force -Path $archive -DestinationPath $unpacked
    if (-not (Test-Path (Join-Path $unpacked "northpane-bridge.exe"))) { Fail 21 "the archive holds no northpane-bridge.exe" }
    & (Join-Path $unpacked "northpane-bridge.exe") self-check --json | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 23 "the downloaded Bridge failed its self-check" }
    New-Item -ItemType Directory -Force -Path $versions | Out-Null
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $unpacked $target

    $currentFile = Join-Path $root "current-version.txt"
    $previous = "none"
    if (Test-Path $currentFile) { $previous = (Get-Content -Raw $currentFile).Trim() }
    if ($previous -ne "none" -and $previous -ne $Version) { [IO.File]::WriteAllText((Join-Path $root "previous-version.txt"), $previous) }
    # A junction needs no administrator rights, unlike a symbolic link, and PATH resolves through it,
    # so the executable finds its DLLs beside it whichever version is active.
    $current = Join-Path $root "current"
    if (Test-Path $current) { (Get-Item $current).Delete() }
    New-Item -ItemType Junction -Path $current -Target $target | Out-Null
    [IO.File]::WriteAllText($currentFile, $Version)
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    if (($userPath -split ';') -notcontains $current) {
        [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(';') + ';' + $current).Trim(';')), "User")
    }
    Say "previous=$previous"
    Say "activated=$Version"

    # Keep the active version and the one before it, so the app can still roll back. An older
    # version whose Bridge is still running cannot be deleted on Windows; it is left for next time
    # rather than failing an install that already succeeded.
    $keep = @($Version)
    $previousFile = Join-Path $root "previous-version.txt"
    if (Test-Path $previousFile) { $keep += (Get-Content -Raw $previousFile).Trim() }
    Get-ChildItem -Directory $versions | Where-Object { $keep -notcontains $_.Name } | ForEach-Object {
        Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
