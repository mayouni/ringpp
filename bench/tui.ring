// The four console builtins, exercised. Results go to a FILE, because
// tui_init() needs stdout to be the console -- redirect it and there is
// nothing to measure. bench/tui_probe.py launches this in a new console,
// waits for the READY file, attaches to that console, and injects the
// keys; under a plain pipe (`printf 'ab' | rnxc exec bench/tui.ring`)
// init answers 0 and tui_key reads bytes, which tests the plumbing
// headless.

$cOut   = "bench/_tui_result.txt"
$cReady = "bench/_tui_ready.txt"
$cLog = ""

$nInit = tui_init()
$cLog += "init " + $nInit + nl

$aSize = tui_size()
$cLog += "size " + $aSize[1] + "x" + $aSize[2] + nl

// tell the harness the console is in raw mode and the next call blocks
write($cReady, "ready")

$k1 = tui_key()
$cLog += "key1 [" + $k1 + "]" + nl
$k2 = tui_key()
$cLog += "key2 [" + $k2 + "]" + nl
$k3 = tui_key()
$cLog += "key3 [" + $k3 + "]" + nl

tui_done()
$cLog += "TUI DONE" + nl
write($cOut, $cLog)
