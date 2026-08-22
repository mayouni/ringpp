# Probe: can this Zig tree still build a Ring++ kernel for every shipped target?
# The global cache is redirected and WIPED before every run -- otherwise a
# cached artifact hides the fact that a needed file was deleted.
param([string]$ZigExe, [string]$Label)

$zt  = "C:\Users\ASUSV3~1\AppData\Local\Temp\claude\D--GitHub-ringpp\fdeaf626-4510-40de-af51-7afcbbf0bc5c\scratchpad\zt"
$src = "$zt\kern.c"

$cache = "$zt\zcache"
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Recurse -Force }
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$env:ZIG_GLOBAL_CACHE_DIR = $cache
$env:ZIG_LOCAL_CACHE_DIR  = "$cache\local"

if (Test-Path -LiteralPath "$zt\out") { Remove-Item -LiteralPath "$zt\out" -Recurse -Force }
New-Item -ItemType Directory -Force -Path "$zt\out" | Out-Null

$targets = @(
  @{ t = "native";             o = "kern-host.dll"       },
  @{ t = "x86_64-windows-gnu"; o = "kern-win-x64.dll"    },
  @{ t = "x86_64-linux-musl";  o = "kern-linux-x64.so"   },
  @{ t = "aarch64-linux-musl"; o = "kern-linux-a64.so"   },
  @{ t = "x86_64-macos-none";  o = "kern-macos-x64.dylib"},
  @{ t = "aarch64-macos-none"; o = "kern-macos-a64.dylib"}
)

$pass = 0; $fail = 0
foreach ($x in $targets) {
    $out = "$zt\out\$($x.o)"
    if ($x.t -eq "native") { $r = & $ZigExe cc -O2 -shared $src -o $out 2>&1 }
    else { $r = & $ZigExe cc -O2 -shared -target $x.t $src -o $out 2>&1 }
    if ($LASTEXITCODE -eq 0 -and (Test-Path $out)) {
        "  ok    {0,-22} {1,8} KB" -f $x.t, ([math]::Round((Get-Item $out).Length/1KB,1))
        $pass++
    } else {
        "  FAIL  {0,-22} {1}" -f $x.t, ((($r | Where-Object { $_ -match 'error' } | Select-Object -First 1)) -join " ")
        $fail++
    }
}
$mb = [math]::Round((Get-ChildItem (Split-Path $ZigExe) -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum/1MB,1)
"{0}: {1} pass, {2} fail   tree = {3} MB" -f $Label, $pass, $fail, $mb
