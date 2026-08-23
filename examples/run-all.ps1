# Every Ring++ example, as a gate.
#
#     powershell -File examples\run-all.ps1
#
# An example is not a brochure here. Each one asserts that the raw-Ring and
# Ring++ paths produce BYTE-IDENTICAL output and prints the measured A/B, so
# running them all is simultaneously the tutorial suite, the correctness
# suite and the benchmark suite. If an example stops being true, this fails.
#
# LEASHED, and not optionally. On 2026-08-21 this machine froze three times
# under work that looked safe; it has 31.6 GB of RAM and a 2 GB page file, so
# memory pressure stops it dead rather than slowing it. Every example runs as
# a child with a hard memory ceiling, a hard timeout, and a system-wide free-RAM
# floor. Worst case is a killed example and a named reason -- never the machine.

param(
    [string]$Ring = "D:\ring127\bin\ring.exe",
    [int]$MaxChildMB = 1024,
    [int]$TimeoutSec = 120,
    [double]$MinFreeGB = 6.0,
    [int]$PollMs = 60,
    [switch]$Quiet
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fail = 0
$ran = 0

function Invoke-Leashed([string]$script, [string]$workdir) {
    $out = [System.IO.Path]::GetTempFileName()
    $err = [System.IO.Path]::GetTempFileName()
    # The path MUST be quoted. Start-Process -ArgumentList takes one command
    # line, not an argv array, so an unquoted path is split on spaces and Ring
    # is handed several arguments instead of one file. Found by cloning the
    # repository into a directory whose name contained a space: all eight
    # examples "failed" identically, having never run. That is every Windows
    # user whose account name has a space in it -- C:\Users\John Smith\ringpp
    # -- which is a large share of them. The rest of the suite uses the call
    # operator (& $Ring $file), which passes argv properly and was never
    # affected; this was the one launch that did not.
    $p = Start-Process -FilePath $Ring -ArgumentList "`"$script`"" -WorkingDirectory $workdir `
        -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $peak = 0
    $verdict = "ok"

    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds $PollMs
        try { $p.Refresh() } catch { break }
        if ($p.HasExited) { break }
        $mb = [int]([Math]::Max($p.WorkingSet64, $p.PrivateMemorySize64) / 1MB)
        if ($mb -gt $peak) { $peak = $mb }
        if ($mb -gt $MaxChildMB) {
            $verdict = "KILLED at $mb MB (ceiling $MaxChildMB)"; try { $p.Kill() } catch {}; break
        }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $verdict = "KILLED at $TimeoutSec s (does not terminate)"; try { $p.Kill() } catch {}; break
        }
        if (((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB) -lt $MinFreeGB) {
            $verdict = "KILLED: machine free RAM below $MinFreeGB GB"; try { $p.Kill() } catch {}; break
        }
    }
    $sw.Stop()
    try { $p.WaitForExit(5000) | Out-Null } catch {}

    $text = (Get-Content $out -ErrorAction SilentlyContinue) -join "`n"
    $errText = (Get-Content $err -ErrorAction SilentlyContinue) -join "`n"
    Remove-Item $out, $err -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Text = $text; Err = $errText; Verdict = $verdict
        PeakMB = $peak; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

"Ring++ examples  (Ring: $Ring)"
"leash: <= $MaxChildMB MB, <= $TimeoutSec s, floor $MinFreeGB GB free"
""

foreach ($dir in (Get-ChildItem $here -Directory | Sort-Object Name)) {
    $script = Join-Path $dir.FullName "example.ring"
    if (-not (Test-Path $script)) { continue }
    $ran++

    $r = Invoke-Leashed $script $dir.FullName

    # An example passes only if it ran to completion AND asserted its own
    # correctness. "EXAMPLE nn OK" is printed after the byte-identical check,
    # so a false speed claim cannot reach this line.
    $okMarker = $r.Text -match "EXAMPLE \d+ OK"
    $identical = $r.Text -match "identical output : 1"
    $ok = ($r.Verdict -eq "ok") -and $okMarker -and $identical

    "{0} {1,-34} {2,6} MB {3,6}s  {4}" -f `
        $(if ($ok) { "PASS" } else { "FAIL" }), $dir.Name, $r.PeakMB, $r.Seconds, `
        $(if ($ok) { "" } else { $r.Verdict })

    if (-not $ok) {
        $script:fail++
        if (-not $okMarker)   { "       did not reach its OK marker" }
        if (-not $identical)  { "       raw and Ring++ outputs DIFFER -- the fast path is wrong" }
        if ($r.Err)           { ($r.Err -split "`n" | Select-Object -First 4) | ForEach-Object { "       $_" } }
    } elseif (-not $Quiet) {
        # the measured line is the point of the example, so surface it
        # anchor on the metric lines only -- an earlier pattern also caught
        # the prose "raw Ring wins" in the honest-half caveat
        ($r.Text -split "`n" | Select-String "^(raw Ring|Ring\+\+|speedup|crossover|RESULT) *:") | ForEach-Object { "       $_" }
    }
}

""
if ($ran -eq 0) { "NO EXAMPLES FOUND"; exit 1 }
if ($fail -eq 0) { "ALL $ran EXAMPLE(S) PASSED" } else { "$fail of $ran EXAMPLE(S) FAILED" }
exit $fail
