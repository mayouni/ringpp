// KNOWN DIVERGENCE, minimal reproduction. Not wired into ab.py, which
// compares FUNCTIONS; this is about top-level execution order, so run it
// by hand:
//
//     ring127\bin\ring.exe bench\loadorder.ring     -> 42
//     rnxc exec bench\loadorder.ring                -> R24, uninitialised
//
// Ring executes a loaded file's top level AT THE LOAD STATEMENT. Ring++
// parses every load up front and runs each file's top level as one block,
// in the order the files were queued -- so a statement AFTER a `load` can
// run before the loaded file's own top level has.
//
// This is not a corner case. Softanza's stzRingLibs.ring does:
//
//     line 113:  load "../../engine/stzMeta.ring"     ($pStzMetaHandle = ...)
//     line 116:  StzMetaInit()                        (reads $pStzMetaHandle)
//
// and under Ring++ line 116 ran first, so the handle was still nil, the
// guard `if $pStzMetaHandle != NULL` passed, and it called into an engine
// that had never been loaded.

$gBefore = 1

load "loadorder_sub.ring"

? "after the load, $gFromSub = " + $gFromSub
