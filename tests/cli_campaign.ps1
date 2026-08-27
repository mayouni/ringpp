# The CLI campaign -- what `ringpp` does when the input is WRONG.
#
# Every other CLI gate points the tool at a fixture built to make it succeed,
# or at one built to make a named rule fire. None of them asked the question
# that matters as much: when the tool CANNOT do what was asked, does it say so?
#
# It did not. `ringpp check typo.ring` answered "0 error ... in 1 files" and
# exited 0 about a file that does not exist -- a clean verdict on nothing,
# from the tool whose entire pitch is that it refuses to guess. deps.zig
# already carries a comment about this exact failure ("an answer that looks
# like a verdict and is actually a measure of what the tool could not see");
# `check` had never been given the same treatment. Found 2026-08-26.
#
# So this gate is adversarial on purpose: absent paths, unreadable files,
# binary rubbish, a 200 KB line, a NUL byte, 400-deep nesting, circular
# loads, and arguments the tool does not understand. Two properties, asserted
# separately:
#
#   1. It never CRASHES on hostile input.
#   2. It never reports a CLEAN result for something it did not check.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe  = Join-Path $root 'zig-out\bin\ringpp.exe'

if (-not (Test-Path $exe)) {
    Write-Host "SKIP cli campaign   zig-out\bin\ringpp.exe not built"
    exit 0
}

$fail = 0
$ran  = 0

function Check-Case {
    param([string]$Name, [string[]]$CliArgs, [int]$WantExit, [string]$MustSay)
    $script:ran++
    $out  = & $exe @CliArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ok = $true
    if ($code -ne $WantExit) {
        Write-Host "  FAIL $Name : exit $code, wanted $WantExit"; $ok = $false
    }
    if ($MustSay -and $out -notmatch [regex]::Escape($MustSay)) {
        Write-Host "  FAIL $Name : output did not contain '$MustSay'"; $ok = $false
    }
    if (-not $ok) { $script:fail++ }
}

# ---- a workspace of deliberately awful files -------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("rppcli-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $w = { param($n, [byte[]]$b) [System.IO.File]::WriteAllBytes((Join-Path $tmp $n), $b) }

    & $w 'good.ring'      ([Text.Encoding]::ASCII.GetBytes("func main`n`t? `"hi`"`n"))
    & $w 'bom.ring'       (@(0xEF,0xBB,0xBF) + [Text.Encoding]::ASCII.GetBytes("func main`n`t? `"b`"`n"))
    & $w 'crlf.ring'      ([Text.Encoding]::ASCII.GetBytes("func main`r`n`t? `"c`"`r`n"))
    & $w 'binary.ring'    ([byte[]](0..255) * 20)
    & $w 'nul.ring'       ([Text.Encoding]::ASCII.GetBytes("func main`n`t? `"a") + @(0x00) + [Text.Encoding]::ASCII.GetBytes("b`"`n"))
    & $w 'unterminated.ring' ([Text.Encoding]::ASCII.GetBytes("func main`n`t? `"never closed`n"))
    & $w 'longline.ring'  ([Text.Encoding]::ASCII.GetBytes("func main`n`t? `"" + ('x' * 200000) + "`"`n"))
    $deep = "func main`n" + ("`tif 1`n" * 400) + ("`tok`n" * 400)
    & $w 'deep.ring'      ([Text.Encoding]::ASCII.GetBytes($deep))
    & $w 'a.ring'         ([Text.Encoding]::ASCII.GetBytes("load `"b.ring`"`nfunc fa`n`treturn 1`n"))
    & $w 'b.ring'         ([Text.Encoding]::ASCII.GetBytes("load `"a.ring`"`nfunc fb`n`treturn 2`n"))
    & $w 'notring.txt'    ([Text.Encoding]::ASCII.GetBytes("not ring at all"))

    # ---- 1. it must never claim a clean result for what it did not check ----
    # Each of these used to print "0 error ... " and exit 0.
    Check-Case 'absent file'     @('check', (Join-Path $tmp 'nope.ring'))      1 'NO VERDICT'
    Check-Case 'absent dir'      @('check', (Join-Path $tmp 'no-such-dir'))    1 'NO VERDICT'
    Check-Case 'no .ring inside' @('check', (Join-Path $tmp 'notring.txt'))    1 'NO VERDICT'

    # ---- 2. arguments it does not understand are refused, not ignored ------
    Check-Case 'unknown option'  @('check', '--fix')                           1 'unknown option'
    # --json is an OPTION, and since check learned --advise it is named as
    # one; the old parser called anything in third position an "argument".
    Check-Case 'unknown option 2' @('check', (Join-Path $tmp 'good.ring'), '--json') 1 'unknown option'
    Check-Case 'extra argument'  @('check', (Join-Path $tmp 'good.ring'), (Join-Path $tmp 'good.ring')) 1 'unexpected argument'

    # ---- 3. hostile CONTENT must not crash, and must still verdict ---------
    foreach ($f in 'good.ring','bom.ring','crlf.ring','binary.ring','nul.ring',
                   'unterminated.ring','longline.ring','deep.ring','a.ring') {
        $script:ran++
        $out  = & $exe check (Join-Path $tmp $f) 2>&1 | Out-String
        $code = $LASTEXITCODE
        # 0 or 1 are both legitimate verdicts. A crash is not: Windows reports
        # those as large values such as 0xC0000409 (-1073740791).
        if ($code -ne 0 -and $code -ne 1) {
            Write-Host "  FAIL hostile/$f : exit $code -- that is a crash, not a verdict"
            $script:fail++
        }
        elseif ($out -notmatch 'error,') {
            Write-Host "  FAIL hostile/$f : produced no summary line"
            $script:fail++
        }
    }

    # ---- 4. a file no rule could run on must not be counted as checked -----
    $script:ran++
    $out = & $exe check (Join-Path $tmp 'unterminated.ring') 2>&1 | Out-String
    if ($out -notmatch 'no rule ran on them') {
        Write-Host "  FAIL unparsed file is not declared in the summary"
        $script:fail++
    }

    # ---- 5. the same input twice gives the same answer ---------------------
    $script:ran++
    $r1 = (& $exe check $tmp 2>&1 | Out-String) -replace '\d+(\.\d+)? ms',''  -replace '\d+(\.\d+)? KB',''
    $r2 = (& $exe check $tmp 2>&1 | Out-String) -replace '\d+(\.\d+)? ms','' -replace '\d+(\.\d+)? KB',''
    if ($r1 -ne $r2) {
        Write-Host "  FAIL check is not deterministic across two runs"
        $script:fail++
    }

    # ---- 6. the commands that already got this right must stay right -------
    Check-Case 'deps absent'   @('deps',  (Join-Path $tmp 'nope.ring')) 1 'no such file'
    Check-Case 'build absent'  @('build', (Join-Path $tmp 'nope.ring')) 1 'no such file'
    Check-Case 'unknown cmd'   @('nonsense')                            1 'unknown command'
    Check-Case 'why unknown'   @('why', 'no-such-rule-at-all')          1 'nothing known'

    # ---- 7. the android target refuses rather than half-packages -----------
    # An APK that installs and then dies on the phone is the worst failure
    # this target can produce, so every way of not having what it needs must
    # stop it before it writes anything.
    Check-Case 'android unknown target' @('build', (Join-Path $tmp 'good.ring'), '--target', 'androidx') 1 'unknown --target'
    Check-Case 'android needs a JDK'    @('build', (Join-Path $tmp 'good.ring'), '--target', 'android', '--sdk', $tmp, '--jdk', (Join-Path $tmp 'no-jdk')) 1 'could not find'

    # The refusal must name the toolchain it wants AND the ones it does not,
    # because "Android build failed" reads to most people as "install the NDK".
    $script:ran++
    $out = & $exe build (Join-Path $tmp 'good.ring') --target android --sdk (Join-Path $tmp 'no-sdk') 2>&1 | Out-String
    if ($out -notmatch 'NOT require the NDK') {
        Write-Host "  FAIL the android refusal does not say the NDK is unnecessary"
        $script:fail++
    }

    # ---- 8. building must not RUN the program (F-37) -----------------------
    # `ring -go` compiles and then executes. Every build shipped that side
    # effect until 2026-08-26; this is the gate that keeps it gone.
    $script:ran++
    $sideEffect = Join-Path $tmp 'BUILT-AND-RAN.txt'
    $prog = Join-Path $tmp 'sideeffect.ring'
    Set-Content -Path $prog -Value ('write("{0}","ran")' -f ($sideEffect -replace '\\','/')) -Encoding ascii
    & $exe build $prog --out (Join-Path $tmp 'sideout') 2>&1 | Out-Null
    # Non-vacuous: without this the gate goes green whenever `ring` is simply
    # absent from PATH, because the build then never reaches the compile step
    # and of course never runs anything. The .ringo proves it DID compile.
    if (-not (Test-Path (Join-Path $tmp 'sideeffect.ringo'))) {
        Write-Host "  SKIP F-37 side-effect gate: no bytecode produced, so nothing was proven"
    } elseif (Test-Path $sideEffect) {
        Write-Host "  FAIL building a program executed it -- FINDINGS F-37 has regressed"
        $script:fail++
    }

    # ---- 9. a reader that leaves early must not crash the tool -------------
    # `ringpp check big | head -2` used to PANIC: MSYS and PowerShell hand
    # the child an OVERLAPPED pipe, and when the reader closes it,
    # kernel32.WriteFile fails with IO_PENDING -- a code Zig's synchronous
    # std wrapper declares unreachable. The fix is ringpp's own pipe-safe
    # stdout writer; this is the gate that keeps it fixed.
    #
    # The fixture must out-write the 8 KB stdout buffer AFTER the reader has
    # gone, or the test is vacuous: 3,000 empty-catch findings is ~1 MB of
    # report against one line read.
    $script:ran++
    $sbBig = New-Object Text.StringBuilder
    $null = $sbBig.AppendLine('func main')
    for ($i = 0; $i -lt 3000; $i++) { $null = $sbBig.AppendLine("`ttry x$i = $i catch done") }
    & $w 'floods.ring' ([Text.Encoding]::ASCII.GetBytes($sbBig.ToString()))

    # It must be an MSYS/Git-Bash pipe. This was learned by writing the gate
    # the obvious way first: a .NET RedirectStandardOutput pipe, PowerShell's
    # native `| Select-Object -First 1`, and cmd.exe's `| findstr` ALL pass
    # against the known-bad binary, because none of them is the overlapped
    # pipe that provokes IO_PENDING. A gate that cannot fail on the defect it
    # names is worse than no gate, so this one runs through bash or declares
    # that it did not run.
    # Derived from git.exe's own location, then the usual install paths. NOT
    # from `Get-Command bash.exe`: on this machine that resolves to WSL's
    # bash, which cannot see Windows paths and fails the test for a reason
    # that has nothing to do with ringpp. Git lives at C:\Git here, so a
    # hardcoded Program Files list would have silently SKIPped forever.
    $bash = $null
    $git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git)   # <root>\cmd\git.exe
        foreach ($rel in @('bin\bash.exe', 'usr\bin\bash.exe')) {
            $cand = Join-Path $gitRoot $rel
            if (Test-Path $cand) { $bash = $cand; break }
        }
    }
    if (-not $bash) {
        foreach ($cand in @('C:\Program Files\Git\bin\bash.exe',
                            'C:\Program Files (x86)\Git\bin\bash.exe',
                            'C:\Git\bin\bash.exe', 'C:\Git\usr\bin\bash.exe')) {
            if (Test-Path $cand) { $bash = $cand; break }
        }
    }
    if (-not $bash) {
        Write-Host "  SKIP early pipe close : no Git Bash found -- only an MSYS pipe reproduces this"
    } else {
        $errFile  = Join-Path $tmp 'pipe.err'
        # The command goes into a SCRIPT FILE, not `bash -c "..."`. Passing a
        # command string with embedded double quotes through PowerShell to a
        # native exe mangles them: bash received the temp path truncated at
        # its first space ("C:/Users/ASUS") and checked nothing, so the gate
        # passed while testing nothing at all. Inside a file, quoting is
        # bash's own business and paths with spaces survive.
        $script  = Join-Path $tmp 'pipeclose.sh'
        $body    = '#!/bin/sh' + "`n" +
                   '"' + ($exe -replace '\\','/') + '" check "' +
                   ((Join-Path $tmp 'floods.ring') -replace '\\','/') + '" 2>"' +
                   ($errFile -replace '\\','/') + '" | head -2 >/dev/null' + "`n"
        [IO.File]::WriteAllText($script, $body, (New-Object Text.UTF8Encoding $false))
        & $bash ($script -replace '\\','/') 2>&1 | Out-Null
        $errText = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
        if ($errText -match 'panic|unreachable') {
            Write-Host "  FAIL early pipe close : panic on stderr after the reader closed the pipe"
            Write-Host ("       " + (($errText -split "`n")[0]).Trim())
            $script:fail++
        }
    }

    # ---- 10. and the good path is still good -------------------------------
    Check-Case 'a clean file'  @('check', (Join-Path $tmp 'good.ring')) 0 '0 error'
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($fail -eq 0) {
    Write-Host ("  CLI CAMPAIGN PASSED -- {0} adversarial cases, 0 false clean, 0 crashes" -f $ran)
    exit 0
} else {
    Write-Host ("  CLI CAMPAIGN FAILED -- {0} of {1} cases" -f $fail, $ran)
    exit 1
}
