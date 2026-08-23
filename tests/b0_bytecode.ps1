# B0 — is a Ring `.ringo` portable across architectures?
#
#     powershell -File tests\b0_bytecode.ps1
#
# The blocking unknown of the build half (docs/DESIGN_BUILD.md §4). If
# bytecode compiled on one platform does not run on another, "build for any
# platform from any platform" is not a product and most of that half closes.
#
# The test: compile a .ringo on THIS host, run it here, run the SAME bytes on
# a Linux runtime, and compare output byte for byte. Two fixtures, because
# they answer different questions:
#
#   pure.ring  — no `load` at all. Isolates the BYTECODE FORMAT.
#   lib.ring   — `load "stdlib.ring"`. stdlib reaches native extensions
#                through loadlib, so this answers a second question the
#                first cannot: what happens to a program whose dependencies
#                are not pure Ring.
#
# A Linux runtime is not assumed. If one is not supplied and cannot be built,
# the gate prints SKIP with the reason and exits 0 — a gate you could not run
# is named, never quietly passed.

param(
    [string]$Ring      = "D:\ring127\bin\ring.exe",
    [string]$LinuxRing = "",                      # an existing linux ring binary
    [string]$RingSrc   = "D:\ring127\language\src",
    [string]$RingInc   = "D:\ring127\language\include",
    [switch]$Quiet
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path $env:TEMP ("rpp_b0_" + [IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force $work | Out-Null

function Say([string]$s) { if (-not $Quiet) { $s } }

# ---------------------------------------------------------------- fixtures
# Deliberately exercises the things most likely to differ across an ABI:
# integer and float formatting, string case, char/ascii, list indexing.
@'
func Main
	? "str  : " + upper("abc")
	? "int  : " + (7 * 6) + " " + (2 ** 10)
	? "float: " + (1/3)
	n = 0
	for i = 1 to 100 n += i next
	? "loop : " + n
	? "char : " + ascii("A") + " " + char(66)
	aL = [3,1,2]
	? "list : " + len(aL) + " " + aL[1] + aL[2] + aL[3]
'@ | Set-Content -Path (Join-Path $work "pure.ring") -Encoding ascii

@'
load "stdlib.ring"

func Main
	? "lib  : " + upper("x")
'@ | Set-Content -Path (Join-Path $work "lib.ring") -Encoding ascii

Push-Location $work

# --------------------------------------------------------- compile on host
foreach ($f in @("pure", "lib")) {
    & $Ring "$f.ring" -go > $null 2>&1
    if (-not (Test-Path "$f.ringo")) {
        "FAIL b0 bytecode     could not produce $f.ringo on the host"
        Pop-Location; Remove-Item $work -Recurse -Force -EA SilentlyContinue; exit 1
    }
}
Say ("  host bytecode : pure {0} bytes, lib {1} bytes" -f `
     (Get-Item "pure.ringo").Length, (Get-Item "lib.ringo").Length)

# The object file is TEXT and carries its own format version, which is not
# the Ring version. Worth printing: it is the thing that would change under
# a future Ring and silently invalidate every packaged program.
$objVer = (Get-Content "pure.ringo" -TotalCount 2)[1]
Say ("  object format : {0}   (Ring reports 1.27.0)" -f $objVer.TrimStart('#').Trim())

# ---------------------------------------------------- reference run (host)
$hostOut = @{}
foreach ($f in @("pure", "lib")) {
    $hostOut[$f] = (& $Ring "$f.ringo" 2>&1 | Out-String).Replace("`r`n", "`n").TrimEnd()
}

# ------------------------------------------------------ get a Linux runtime
$skip = ""
if (-not $LinuxRing) {
    $zig = Get-Command zig -EA SilentlyContinue
    if (-not $zig) {
        $skip = "no -LinuxRing supplied and no zig on PATH to cross-compile one"
    } elseif (-not (Test-Path $RingSrc)) {
        $skip = "no -LinuxRing supplied and Ring VM sources not at $RingSrc"
    } else {
        Say "  building a Linux x86_64-musl Ring runtime with zig cc (~25 s)..."
        Push-Location $RingSrc
        $srcs = (Get-ChildItem *.c | Where-Object { $_.Name -ne "ringw.c" }).Name
        & zig cc -target x86_64-linux-musl -O2 -w -I $RingInc $srcs -o (Join-Path $work "ring_linux") -lm 2>&1 | Out-Null
        $built = $LASTEXITCODE
        Pop-Location
        if ($built -ne 0 -or -not (Test-Path (Join-Path $work "ring_linux"))) {
            $skip = "zig cc could not build a Linux Ring runtime (exit $built)"
        } else { $LinuxRing = Join-Path $work "ring_linux" }
    }
}
if (-not $skip) {
    $wsl = Get-Command wsl -EA SilentlyContinue
    if (-not $wsl) { $skip = "a Linux runtime exists but there is no WSL to run it in" }
}

if ($skip) {
    "SKIP b0 bytecode     $skip"
    Pop-Location; Remove-Item $work -Recurse -Force -EA SilentlyContinue
    exit 0
}

# ------------------------------------------------------- run the SAME bytes
# Staged through the repo directory because WSL resolves /mnt paths reliably
# and $env:TEMP contains spaces on this machine.
$stage = Join-Path $root ".b0_stage"
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $LinuxRing (Join-Path $stage "rl") -Force
Copy-Item "pure.ringo", "lib.ringo" $stage -Force
$drive = ($root.Substring(0,1)).ToLower()
$mnt = "/mnt/$drive" + ($root.Substring(2) -replace '\\','/') + "/.b0_stage"

$linOut = @{}
foreach ($f in @("pure", "lib")) {
    $cmd = "cp $mnt/rl /tmp/rl && chmod +x /tmp/rl && cp $mnt/$f.ringo /tmp/ && cd /tmp && ./rl $f.ringo 2>&1"
    $linOut[$f] = (& wsl -d Ubuntu -- bash -c $cmd | Out-String).Replace("`r`n", "`n").TrimEnd()
}
Remove-Item $stage -Recurse -Force -EA SilentlyContinue

# ----------------------------------------------------------------- verdict
$fail = 0
foreach ($f in @("pure", "lib")) {
    $same = ($hostOut[$f] -eq $linOut[$f])
    $label = if ($f -eq "pure") { "pure Ring (no load)" } else { "load stdlib.ring" }
    if ($same) {
        Say ("  {0,-22} IDENTICAL on both platforms" -f $label)
    } else {
        Say ("  {0,-22} DIFFERS" -f $label)
        Say  "     host  : $($hostOut[$f] -split "`n" | Select-Object -First 2)"
        Say  "     linux : $($linOut[$f]  -split "`n" | Select-Object -First 2)"
    }
    if ($f -eq "pure" -and -not $same) { $fail++ }   # only `pure` is the gate
}

# `lib` is REPORTED, not gated. It is expected to differ -- stdlib reaches
# native extensions, and a failed loadlib is silent on Windows and fatal on
# Linux (FINDINGS F-29). Gating it would be asserting a defect.
$libSame = ($hostOut["lib"] -eq $linOut["lib"])
if (-not $libSame) {
    Say "  note: the stdlib fixture differing is EXPECTED and is the second"
    Say "        half of the finding -- see FINDINGS F-29, not a regression."
}

Pop-Location
Remove-Item $work -Recurse -Force -EA SilentlyContinue

"{0} {1,-16} {2}" -f $(if ($fail -eq 0) { "PASS" } else { "FAIL" }), "b0 bytecode", `
    $(if ($fail -eq 0) { "pure-Ring bytecode is portable x64 Windows -> Linux" } else { "bytecode is NOT portable" })
exit $fail
