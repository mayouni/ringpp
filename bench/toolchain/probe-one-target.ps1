# Probe ONE target against a tree, cold cache.
param([string]$ZigExe, [string]$Target, [string]$Out)

$zt = "C:\Users\ASUSV3~1\AppData\Local\Temp\claude\D--GitHub-ringpp\fdeaf626-4510-40de-af51-7afcbbf0bc5c\scratchpad\zt"
$cache = "$zt\zcache"
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR = $cache
$env:ZIG_LOCAL_CACHE_DIR  = "$cache\local"

$o = "$zt\out\$Out"
if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force }
$r = & $ZigExe cc -O2 -shared -target $Target "$zt\kern.c" -o $o 2>&1
$mb = [math]::Round((Get-ChildItem (Split-Path $ZigExe) -Recurse -File | Measure-Object -Property Length -Sum).Sum/1MB,1)
if ($LASTEXITCODE -eq 0 -and (Test-Path $o)) {
    "  OK   {0,-20} tree={1,6} MB  artifact={2} KB" -f $Target, $mb, ([math]::Round((Get-Item $o).Length/1KB,1))
} else {
    "  FAIL {0,-20} tree={1,6} MB  {2}" -f $Target, $mb, ((($r | Where-Object { $_ -match 'error|not found|FileNotFound' } | Select-Object -First 1)) -join " ")
}
