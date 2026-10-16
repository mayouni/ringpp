# Probe ONE target against a tree, cold cache.
param(
    [string]$ZigExe,
    [string]$Target,
    [string]$Out,
    # Scratch for the wiped cache and the throwaway artifacts. This was a
    # hardcoded absolute path into a session scratchpad, which stopped existing
    # when that session did -- so the script has been unrunnable ever since,
    # and it failed by building into nowhere rather than by saying so. kern.c
    # is tracked in the repository beside this script, so only the disposable
    # half needs a temp directory, and it is derived at run time rather than
    # frozen into a name only one machine-minute could ever resolve.
    [string]$WorkDir = (Join-Path $env:TEMP "ringpp-zt")
)

$src = Join-Path $PSScriptRoot "kern.c"
if (-not (Test-Path -LiteralPath $src)) {
    "probe-one-target.ps1: no kern.c beside this script at $src"
    "kern.c is tracked in this repository -- the checkout is missing a file."
    exit 2
}
if (-not $ZigExe -or -not (Test-Path -LiteralPath $ZigExe)) {
    "probe-one-target.ps1: -ZigExe must point at a zig executable (got '$ZigExe')"
    exit 2
}

$cache = Join-Path $WorkDir "zcache"
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR = $cache
$env:ZIG_LOCAL_CACHE_DIR  = Join-Path $cache "local"

$outDir = Join-Path $WorkDir "out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$o = Join-Path $outDir $Out
if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force }
$r = & $ZigExe cc -O2 -shared -target $Target $src -o $o 2>&1
$mb = [math]::Round((Get-ChildItem (Split-Path $ZigExe) -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB,1)
if ($LASTEXITCODE -eq 0 -and (Test-Path $o)) {
    "  OK   {0,-20} tree={1,6} MB  artifact={2} KB" -f $Target, $mb, ([math]::Round((Get-Item $o).Length/1KB,1))
} else {
    "  FAIL {0,-20} tree={1,6} MB  {2}" -f $Target, $mb, ((($r | Where-Object { $_ -match 'error|not found|FileNotFound' } | Select-Object -First 1)) -join " ")
}
