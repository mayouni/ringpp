param(
    [string]$Root,
    [string]$Label,
    [int]$Max = 100000,
    # The probe binary. This was once a hardcoded absolute path into a session
    # scratchpad, which stopped existing when that session did -- so the script
    # was dead for everyone who ran it afterwards, including its author. A path
    # only one machine-minute can resolve is not a default, it is a fossil.
    # tsprobe.c lives beside this script; build it here and the default finds it.
    [string]$Probe = (Join-Path $PSScriptRoot "tsprobe.exe")
)

# WHAT THIS SCRIPT IS, AND IS NOT. It counts tsprobe exit codes. It does NOT
# adjudicate: nothing here asks Ring whether a file it flagged is really
# invalid, so a number from this script is a parse-failure count and never a
# disagreement rate. tests\fidelity.ps1 is the harness that adjudicates, with
# `ring <file> -norun`, and it is where the corpus rates in
# upstream\tree-sitter-ring-notes.md come from. Do not quote this one as those.
if (-not (Test-Path -LiteralPath $Probe)) {
    $repo = Split-Path (Split-Path $PSScriptRoot)
    "sweep.ps1: no probe binary at $Probe"
    ""
    "Build it from tsprobe.c beside this script (README.md, 'Reproducing')."
    "This compiles the grammar's 21.8 MB generated table -- one job, seconds to"
    "a minute, and the only heavy thing here:"
    ""
    "  zig cc -O2 ``"
    "      -I $repo\vendor\tree-sitter\include -I $repo\vendor\tree-sitter\src ``"
    "      -I $repo\vendor\tree-sitter-ring\src ``"
    "      $repo\vendor\tree-sitter\src\lib.c ``"
    "      $repo\vendor\tree-sitter-ring\src\parser.c ``"
    "      $repo\vendor\tree-sitter-ring\src\scanner.c ``"
    "      $PSScriptRoot\tsprobe.c -o $Probe"
    ""
    "Or pass -Probe with a path to one you already have."
    exit 2
}
$files = Get-ChildItem $Root -Recurse -File -Filter *.ring -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\vendor\\|-copy|- Copie' } |
         Select-Object -First $Max

$ok = 0; $bad = 0; $bytes = 0; $badlist = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($f in $files) {
    $null = & $Probe $f.FullName --quiet 2>&1
    if ($LASTEXITCODE -eq 0) { $ok++ } else { $bad++; $badlist += $f.FullName }
    $bytes += $f.Length
}
$sw.Stop()
"{0,-22} {1,5} files  {2,8:N1} KB  clean {3,5}  errors {4,4}  ({5:P1} clean)  {6:N1} s wall" -f `
   $Label, $files.Count, ($bytes/1KB), $ok, $bad, ($(if($files.Count){$ok/$files.Count}else{0})), $sw.Elapsed.TotalSeconds
if ($bad -gt 0) {
    "  files with parse errors (first 12):"
    $badlist | Select-Object -First 12 | ForEach-Object { "    " + $_.Replace($Root, "") }
}
