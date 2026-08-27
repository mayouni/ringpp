# Ring++ on Android — the device campaign.
#
#     powershell -File tests\android_campaign.ps1
#
# Runs the library's own gates on a physical arm64 phone, then the algorithm
# suite on BOTH the desktop and the phone, and requires their CHECK lines to
# be byte-identical. That last part is the point: it turns "Ring++ probably
# works on ARM" into a statement with evidence behind it, because the same
# source produced the same answers on two different instruction sets.
#
# OPTIONAL BY DESIGN. No phone, no ADB, or an unauthorised device and this
# prints SKIP with the reason and exits 0. A gate that cannot run is named,
# never quietly passed -- and "there is no phone plugged into this machine"
# is a legitimate reason.
#
# It also benchmarks two other runtimes that can be put on the same phone,
# when they are available: Android's own ART (always present) and Lua 5.4
# (only if a static arm64 build has been placed in the scratch directory).
# Neither is required; each is reported as measured or as absent.

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$dev  = '/data/local/tmp/rpp'
$fail = 0

function Say($m) { Write-Host $m }
function Skip($why) { Say "  SKIP android campaign -- $why"; exit 0 }

# ---------------------------------------------------------------- adb
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
if ($env:ANDROID_HOME) { $adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe' }
if (-not (Test-Path $adb)) { Skip "no adb at $adb" }

$devices = @(& $adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\S' })
# @() is not decoration. With one device attached the pipeline yields a bare
# string, and $ready[0] then indexes its first CHARACTER -- the campaign went
# looking for a device called "0" and reported seven failures that were
# entirely its own.
$ready   = @($devices | Where-Object { $_ -match '\sdevice\s*$' })
if ($ready.Count -eq 0) {
    $state = if ($devices.Count) { ($devices -join '; ').Trim() } else { 'none attached' }
    Skip "no authorised device ($state)"
}
$serial = ($ready[0] -split '\s+')[0]
Say "  device: $serial"

# ------------------------------------------------------- the arm64 VM
$vm = Join-Path $root 'runtime\linux-arm64\ring'
if (-not (Test-Path $vm)) { Skip "no arm64 runtime stub -- run tests\b2_runtimes.ps1 first" }

# ------------------------------------------------------------ staging
& $adb -s $serial shell "rm -rf $dev; mkdir -p $dev/rpp $dev/tests $dev/android/bench" | Out-Null
& $adb -s $serial push $vm "$dev/ring" | Out-Null
& $adb -s $serial shell "chmod 755 $dev/ring" | Out-Null
& $adb -s $serial push (Join-Path $root 'ringpp.ring') "$dev/" | Out-Null
foreach ($f in 'core','idioms','probe') {
    & $adb -s $serial push (Join-Path $root "rpp\$f.ring") "$dev/rpp/" | Out-Null
}
foreach ($f in 'probe_smoke','buffer','idioms','name_collision','differential','fuzz_bounds') {
    & $adb -s $serial push (Join-Path $root "tests\$f.ring") "$dev/tests/" | Out-Null
}
& $adb -s $serial push (Join-Path $root 'android\bench\algorithms.ring') "$dev/android/bench/" | Out-Null

# ------------------------------------------------- 1. the gates, on ARM
# These are the same files tests\run-all.ps1 runs on the desktop. Nothing
# about them is Android-aware; that is what makes passing meaningful.
$gates = 'probe_smoke','buffer','idioms','name_collision','differential','fuzz_bounds'
foreach ($g in $gates) {
    $out = & $adb -s $serial shell "cd $dev/tests && ../ring $g.ring 2>&1" | Out-String
    # Every one of these gates prints its own failure count. A gate that
    # printed nothing at all is a failure too -- that is what an unreadable
    # binary or a missing file looks like from here.
    if ($out -match '(\d+)\s+failed' -and [int]$Matches[1] -gt 0) {
        Say "  FAIL gate $g -- $($Matches[1]) failed on device"; $fail++
    } elseif ($out -notmatch '\S') {
        Say "  FAIL gate $g -- no output from the device"; $fail++
    } elseif ($out -match 'Error \(') {
        Say "  FAIL gate $g -- Ring error on device"
        Say ("       " + (($out -split "`n" | Where-Object { $_ -match 'Error \(' })[0]).Trim())
        $fail++
    } else {
        Say "  PASS gate $g"
    }
}

# ------------------------------- 2. same source, two instruction sets
$ring = 'D:\ring127\bin\ring.exe'
if (-not (Test-Path $ring)) { $ring = (Get-Command ring -ErrorAction SilentlyContinue).Source }

function ChecksOf($text) {
    ($text -split "`n" | Where-Object { $_ -match '^CHECK ' } | ForEach-Object { $_.Trim() }) -join "`n"
}

$deviceOut = & $adb -s $serial shell "cd $dev/android/bench && ../../ring algorithms.ring 2>&1" | Out-String
if ($deviceOut -notmatch 'SUITE OK') {
    Say "  FAIL algorithm suite did not finish on the device"
    Say ("       " + ($deviceOut -split "`n" | Select-Object -Last 3 | Out-String).Trim())
    $fail++
} elseif ($ring -and (Test-Path $ring)) {
    Push-Location (Join-Path $root 'android\bench')
    $hostOut = & $ring algorithms.ring 2>&1 | Out-String
    Pop-Location
    $a = ChecksOf $hostOut
    $b = ChecksOf $deviceOut
    if ($a -ne $b) {
        Say "  FAIL x64 and arm64 disagree on a computed result:"
        $al = $a -split "`n"; $bl = $b -split "`n"
        for ($i = 0; $i -lt [Math]::Max($al.Count, $bl.Count); $i++) {
            if ($al[$i] -ne $bl[$i]) { Say "       x64: $($al[$i])`n       arm: $($bl[$i])" }
        }
        $fail++
    } else {
        $n = ($a -split "`n").Count
        Say "  PASS $n computed results byte-identical on x64 and arm64"
    }
    # Timings are reported, never asserted: they are hardware, not behaviour.
    Say ""
    Say "  --- same algorithms, both machines (ms, minimum of 3) ---"
    $ht = @{}; ($hostOut -split "`n") | Where-Object { $_ -match '^TIME\s+(\S+)\s+(\S+)' } | ForEach-Object {
        $null = $_ -match '^TIME\s+(\S+)\s+(\S+)'; $ht[$Matches[1]] = $Matches[2] }
    ($deviceOut -split "`n") | Where-Object { $_ -match '^TIME\s+(\S+)\s+(\S+)' } | ForEach-Object {
        $null = $_ -match '^TIME\s+(\S+)\s+(\S+)'
        $k = $Matches[1]; $d = [double]$Matches[2]
        $h = if ($ht.ContainsKey($k)) { [double]$ht[$k] } else { 0 }
        $r = if ($h -gt 0) { '{0,6:N1}x' -f ($d / $h) } else { '     -' }
        Say ('    {0,-22} x64 {1,9:N2}   arm64 {2,9:N2}   {3}' -f $k, $h, $d, $r)
    }
    Say ""
} else {
    Say "  SKIP x64/arm64 comparison -- no desktop Ring found to compare against"
}

# --------------------------------- 3. the neighbours, on the same phone
# Reported, never gated: another runtime's speed is not this project's to
# pass or fail on. It is here so the numbers come from one phone in one
# session rather than from three different articles.
Say "  --- other runtimes on this same device ---"

$dexDir = Join-Path $root 'android\bench\out'
$dex    = Join-Path $dexDir 'classes.dex'
if (Test-Path $dex) {
    & $adb -s $serial push $dex "$dev/bench.dex" | Out-Null
    $artOut = & $adb -s $serial shell "cd $dev && dalvikvm -cp bench.dex Bench 2>&1" | Out-String
    if ($artOut -match 'SUITE OK') { Say "    ART (dalvikvm) : ran" } else { Say "    ART (dalvikvm) : did not finish" }
} else {
    Say "    ART (dalvikvm) : not built -- see android\bench\README.md"
    $artOut = ''
}

$lua = Join-Path $env:TEMP 'claude\ringpp-lua\lua-arm64'
if (Test-Path $lua) {
    & $adb -s $serial push $lua "$dev/lua" | Out-Null
    & $adb -s $serial push (Join-Path $root 'android\bench\bench.lua') "$dev/android/bench/" | Out-Null
    & $adb -s $serial shell "chmod 755 $dev/lua" | Out-Null
    $luaOut = & $adb -s $serial shell "cd $dev/android/bench && ../../lua bench.lua 2>&1" | Out-String
    if ($luaOut -match 'SUITE OK') { Say "    Lua 5.4        : ran" } else { Say "    Lua 5.4        : did not finish" }
} else {
    Say "    Lua 5.4        : absent -- see android\bench\README.md to build one"
    $luaOut = ''
}

# A neighbour that disagrees about an ANSWER is a bug in the comparison and
# makes its timings meaningless, so that part IS checked.
foreach ($pair in @(@('ART', $artOut), @('Lua', $luaOut))) {
    if ($pair[1] -match 'SUITE OK') {
        $theirs = ChecksOf $pair[1]
        $ours = (ChecksOf $deviceOut) -split "`n" | Where-Object { $_ -match '^CHECK (sieve|matmul|fib|mergesort|binsearch|bytescan) ' }
        $t = $theirs -split "`n"
        $bad = @()
        foreach ($line in $t) { if ($ours -notcontains $line) { $bad += $line } }
        if ($bad) {
            Say "  FAIL $($pair[0]) computed a different answer than Ring:"
            $bad | ForEach-Object { Say "       $_" }
            $fail++
        } else {
            Say "    $($pair[0]): all $($t.Count) answers agree with Ring"
        }
    }
}

Say ""
if ($fail -eq 0) {
    Say "  ANDROID CAMPAIGN PASSED"
    exit 0
} else {
    Say "  ANDROID CAMPAIGN FAILED -- $fail check(s)"
    exit 1
}
