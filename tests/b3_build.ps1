# B3 — `ringpp build`: assemble the artefact.
#
#     powershell -File tests\b3_build.ps1
#
# The command B1 (what must ship) and B2 (a runtime per platform) were both
# building toward. Exercises both shapes `deps` can report — PURE RING and
# BUNDLE — and, harder than the happy path, two refusals: an unresolved load
# closure (nothing may be silently declared complete), and Ring's Qt bridge
# (nothing may be silently declared safe to bundle — see case E).
#
# Every case is checked in ISOLATION: the built output is copied to a clean
# directory with nothing else present, and run from there. That is B0's own
# isolation test, generalised into the actual product.

param(
    [string]$Ring    = "D:\ring127\bin\ring.exe",
    [string]$RingRoot = "D:\ring127",
    [switch]$Quiet
)

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
function Say([string]$s) { if (-not $Quiet) { $s } }

# Same resolution as tests\run-all.ps1: prefer a fresh build, fall back to
# the shipped binary, never assume one exists.
$ringpp = $null
foreach ($cand in @("zig-out\bin\ringpp.exe", "bin\win64\ringpp.exe")) {
    if (Test-Path (Join-Path $root $cand)) { $ringpp = Join-Path $root $cand; break }
}
if (-not $ringpp) { "SKIP b3 build       no ringpp.exe in zig-out\bin or bin\win64"; exit 0 }
if (-not (Test-Path $Ring)) { "SKIP b3 build       no Ring at $Ring"; exit 0 }

$work = Join-Path $env:TEMP ("rpp_b3_" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $work | Out-Null
$fail = 0

# $srcDir may not exist -- a compile failure inside `ringpp build` returns
# before the output directory is ever created, and this must report that
# cleanly rather than let Copy-Item throw into the console.
function Isolate([string]$srcDir) {
    if (-not (Test-Path $srcDir)) { return $null }
    $iso = Join-Path $work ("iso_" + [IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force $iso | Out-Null
    Copy-Item (Join-Path $srcDir "*") $iso -Recurse -Exclude "BUILD-MANIFEST.txt"
    return $iso
}

# ------------------------------------------------------------- case A: pure
@'
func Main
	? "case A: " + (6*7)
'@ | Set-Content -Path (Join-Path $work "pure.ring") -Encoding ascii

$outA = Join-Path $work "pure-win64"
$rA = & $ringpp build (Join-Path $work "pure.ring") --ring $Ring --out $outA 2>&1 | Out-String
$isoA = Isolate $outA
$gotA = ""
if ($isoA) {
    $exeA = Join-Path $isoA "pure.exe"
    if (Test-Path $exeA) {
        Push-Location $isoA
        $gotA = (& .\pure.exe pure.ringo 2>&1 | Out-String).Trim()
        Pop-Location
    }
}
$okA = ($gotA -eq "case A: 42")
"{0} {1,-16} {2}" -f $(if ($okA) { "PASS" } else { "FAIL" }), "b3 pure", `
    $(if ($okA) { "isolated pair runs, PURE RING" } else { "got: '$gotA'" })
if (-not $okA) { $fail++; $rA -split "`n" | Select-Object -Last 6 | ForEach-Object { "       $_" } }

# ------------------------------------------------------------ case B: bundle
@'
load "stdlib.ring"

func Main
	? "case B: " + upper("ok")
'@ | Set-Content -Path (Join-Path $work "bundle.ring") -Encoding ascii

$outB = Join-Path $work "bundle-win64"
$rB = & $ringpp build (Join-Path $work "bundle.ring") --ring $Ring --ring-root $RingRoot `
        --lib-dir (Join-Path $RingRoot "bin") --out $outB 2>&1 | Out-String
$isoB = Isolate $outB
$gotB = ""
$dllsB = 0
if ($isoB) {
    $exeB = Join-Path $isoB "bundle.exe"
    if (Test-Path $exeB) {
        Push-Location $isoB
        $gotB = (& .\bundle.exe bundle.ringo 2>&1 | Out-String).Trim()
        Pop-Location
    }
    $dllsB = @(Get-ChildItem $isoB -Filter "*.dll" -EA SilentlyContinue).Count
}
$okB = ($gotB -eq "case B: OK") -and ($dllsB -ge 6)
"{0} {1,-16} {2}" -f $(if ($okB) { "PASS" } else { "FAIL" }), "b3 bundle", `
    $(if ($okB) { "isolated pair + $dllsB libs runs, reaches stdlib" } else { "got: '$gotB', $dllsB dlls" })
if (-not $okB) { $fail++; $rB -split "`n" | Select-Object -Last 6 | ForEach-Object { "       $_" } }

# ------------------------------------------------- case C: refuses, honestly
# Gated HARDER than the happy path, same discipline as B1's own third check.
# No --ring-root: the load closure cannot be followed, so this must exit
# non-zero and must NOT produce a manifest claiming completeness. A build
# tool that answers "nothing missing" when it could not look is the exact
# defect B1 was written to stop, and it would be worse here — believed at
# the moment someone ships.
$outC = Join-Path $work "bundle-noroot"
& $ringpp build (Join-Path $work "bundle.ring") --ring $Ring --out $outC 2>&1 | Out-Null
$refusedC = ($LASTEXITCODE -ne 0)
$mfC = Get-Content (Join-Path $outC "BUILD-MANIFEST.txt") -Raw -EA SilentlyContinue
$saysIncompleteC = ($mfC -match "INCOMPLETE PICTURE")
$okC = $refusedC -and $saysIncompleteC
"{0} {1,-16} {2}" -f $(if ($okC) { "PASS" } else { "FAIL" }), "b3 refuses", `
    $(if ($okC) { "no --ring-root -> non-zero exit, manifest says INCOMPLETE" } else { "exit=$LASTEXITCODE incomplete-text=$saysIncompleteC" })
if (-not $okC) { $fail++ }

# --------------------------------------------- case E: refuses Qt, honestly
# `ringqt.dll` is the only thing loadlib scanning can name for a guilib
# program, but it itself links ~75 further Qt DLLs at the OS loader level --
# invisible to this tool by construction. Measured directly (not assumed):
# bundling just ringqt.dll produced a manifest saying nothing was missing,
# and the isolated package then crashed with NO diagnostic at all (Windows
# exit 0xC0000409). Per the project's dependency-free principle, Ring++
# does not package Qt programs -- this asserts the refusal is real, not
# just documented.
@'
load "guilib.ring"

func Main
	? "would need a Qt window here"
'@ | Set-Content -Path (Join-Path $work "qt.ring") -Encoding ascii

$outE = Join-Path $work "qt-win64"
& $ringpp build (Join-Path $work "qt.ring") --ring $Ring --ring-root $RingRoot `
    --lib-dir (Join-Path $RingRoot "bin") --out $outE 2>&1 | Out-Null
$refusedE = ($LASTEXITCODE -ne 0)
$noOutputE = -not (Test-Path $outE)
$okE = $refusedE -and $noOutputE
"{0} {1,-16} {2}" -f $(if ($okE) { "PASS" } else { "FAIL" }), "b3 no-qt", `
    $(if ($okE) { "reaches ringqt -> refused, no partial package written" } else { "exit=$LASTEXITCODE outputWritten=$(-not $noOutputE)" })
if (-not $okE) { $fail++ }

Remove-Item $work -Recurse -Force -EA SilentlyContinue

# --------------------------------------------------- case D: cross-target
# Optional: only if WSL is present. Not a SKIP of the whole gate -- cases
# A-C already ran -- just this one narrower check, named if it cannot run.
$wsl = Get-Command wsl -EA SilentlyContinue
if ($wsl) {
    $workD = Join-Path $root ".b3_stage"
    New-Item -ItemType Directory -Force $workD | Out-Null
    @'
func Main
	? "case D: " + (6*7)
'@ | Set-Content -Path (Join-Path $workD "cross.ring") -Encoding ascii
    $outD = Join-Path $workD "cross-linux"
    & $ringpp build (Join-Path $workD "cross.ring") --ring $Ring --target linux-x64 --out $outD 2>&1 | Out-Null
    $builtD = (Test-Path (Join-Path $outD "cross")) -and (Test-Path (Join-Path $outD "cross.ringo"))
    $gotD = ""
    if ($builtD) {
        $drive = ($root.Substring(0,1)).ToLower()
        $mnt = "/mnt/$drive" + ($root.Substring(2) -replace '\\','/') + "/.b3_stage/cross-linux"
        $cmd = "cp $mnt/cross /tmp/c3 && chmod +x /tmp/c3 && cp $mnt/cross.ringo /tmp/ && cd /tmp && ./c3 cross.ringo 2>&1"
        $gotD = (& wsl -d Ubuntu -- bash -c $cmd | Out-String).Trim()
    }
    Remove-Item $workD -Recurse -Force -EA SilentlyContinue
    $okD = ($gotD -eq "case D: 42")
    "{0} {1,-16} {2}" -f $(if ($okD) { "PASS" } else { "FAIL" }), "b3 cross", `
        $(if ($okD) { "built on Windows for linux-x64, runs isolated under WSL" } else { "got: '$gotD'" })
    if (-not $okD) { $fail++ }
} else {
    Say "     b3 cross         SKIP (no WSL) -- cases A-C already gate the mechanism"
}

exit $fail
