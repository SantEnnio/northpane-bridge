# Builds the Windows Bridge and packs it with every DLL it needs that Windows itself does not
# provide: the Swift runtime and Foundation, and the Visual C++ runtime (app-local deployment of
# vcruntime is allowed by its redistribution terms). The Universal CRT ships with Windows 10+.
#
#   Scripts/package-windows.ps1 [-Version <expected version>] [-OutputDirectory artifacts]
#
# Output: northpane-bridge-windows-<arch>.zip holding northpane-bridge.exe and its DLLs, and its .sha256.
param(
    [string]$Version = "",
    [string]$OutputDirectory = ".release-artifacts"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

switch ($env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { $platform = "windows-x86_64"; $hostDir = "Hostx64\x64" }
    "ARM64" { $platform = "windows-arm64"; $hostDir = "Hostarm64\arm64" }
    default { throw "unsupported architecture $($env:PROCESSOR_ARCHITECTURE)" }
}

swift build --package-path $root -c release --product northpane-bridge
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$binDir = (swift build --package-path $root -c release --show-bin-path).Trim()
$exe = Join-Path $binDir "northpane-bridge.exe"

$dumpbin = Get-ChildItem -Recurse -Filter dumpbin.exe "${env:ProgramFiles}\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\$hostDir\dumpbin.exe" } | Select-Object -First 1
if (-not $dumpbin) { throw "dumpbin.exe not found (Visual Studio C++ tools)" }

function Get-Dependencies([string]$image) {
    $inList = $false
    foreach ($line in & $dumpbin.FullName /nologo /dependents $image) {
        if ($line -match 'Image has the following dependencies') { $inList = $true; continue }
        if ($inList) {
            $name = $line.Trim()
            if ($name -eq "") { if ($script:seenAny) { break } else { continue } }
            if ($name -match '^Summary') { break }
            $script:seenAny = $true
            $name
        }
    }
}

# Windows' own libraries stay out of the package; everything else is looked up on PATH (the Swift
# runtime directory is on it wherever the toolchain is installed) or next to System32 for vcruntime.
function Test-SystemLibrary([string]$name) {
    $lower = $name.ToLowerInvariant()
    if ($lower.StartsWith("api-ms-win-") -or $lower.StartsWith("ext-ms-")) { return $true }
    if ($lower -like "vcruntime*" -or $lower -like "msvcp*") { return $false }
    return Test-Path (Join-Path $env:SystemRoot "System32\$name")
}

function Find-Library([string]$name) {
    foreach ($dir in ($env:Path -split ';')) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir $name
        if (Test-Path $candidate) { return $candidate }
    }
    $system = Join-Path $env:SystemRoot "System32\$name"
    if (Test-Path $system) { return $system }
    throw "cannot find $name"
}

$package = Join-Path ([IO.Path]::GetTempPath()) ("northpane-bridge-package-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $package | Out-Null
Copy-Item $exe (Join-Path $package "northpane-bridge.exe")

$pending = New-Object System.Collections.Queue
$pending.Enqueue($exe)
$bundled = @{}
while ($pending.Count -gt 0) {
    $script:seenAny = $false
    foreach ($dependency in Get-Dependencies $pending.Dequeue()) {
        $key = $dependency.ToLowerInvariant()
        if ($bundled.ContainsKey($key) -or (Test-SystemLibrary $dependency)) { continue }
        $path = Find-Library $dependency
        $bundled[$key] = $path
        Copy-Item $path (Join-Path $package $dependency)
        $pending.Enqueue($path)
    }
}
Write-Output "bundled: $(($bundled.Keys | Sort-Object) -join ', ')"

# The package must run with nothing but Windows on PATH.
$savedPath = $env:Path
try {
    $env:Path = "$env:SystemRoot\System32;$env:SystemRoot"
    $reported = & (Join-Path $package "northpane-bridge.exe") --version
    if ($LASTEXITCODE -ne 0) { throw "the packaged Bridge does not start without the toolchain" }
    & (Join-Path $package "northpane-bridge.exe") self-check --json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "the packaged Bridge fails its self-check" }
} finally {
    $env:Path = $savedPath
}
Write-Output $reported
if ($Version -and -not ($reported -like "northpane-bridge $Version *")) { throw "the Bridge reports '$reported', expected $Version" }

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$zip = Join-Path $OutputDirectory "northpane-bridge-$platform.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $package "*") -DestinationPath $zip
$digest = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
Set-Content -NoNewline -Path "$zip.sha256" -Value "$digest  northpane-bridge-$platform.zip`n"
Remove-Item -Recurse -Force $package
Write-Output (Resolve-Path $zip).Path
