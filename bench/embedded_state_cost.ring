# What an isolated Ring VM state costs, and why the readable form of the
# idiom cannot be fixed.
#
#     ring embedded_state_cost.ring leak     -- as published
#     ring embedded_state_cost.ring free     -- with ring_state_delete
#
# Measure the PEAK WORKING SET of each run from outside, e.g.
#
#   $p = Start-Process ring.exe -ArgumentList 'embedded_state_cost.ring leak' `
#          -PassThru -NoNewWindow
#   while(-not $p.HasExited){ $p.Refresh(); $max=[Math]::Max($max,$p.WorkingSet64) }
#
# Measured 2026-08-31, Ring 1.27, 200 iterations:
#
#     leak (as published)          2,353 MB
#     free (ring_state_delete)        30 MB
#                                  ---------
#     ~11.6 MB per state
#
# At 2,000 iterations the unfreed form peaked at 20 GB.
#
# The point is not that Ring leaks -- the documentation calls
# ring_state_delete and says plainly "So you can call ring_state_delete()
# at some point to avoid the memory leak!". The point is that
#
#     ring_state_runcode( ring_state_init(), code )
#
# never binds the state to a name, so there is NO POINTER LEFT TO DELETE.
# The spelling that reads best is the one that makes the fix unreachable,
# and Ring has no destructor or scope-exit hook to do it for you.

cMode = "leak"
if len(sysargv) >= 3 cMode = lower(sysargv[3]) ok

nIter = 200
? "mode: " + cMode + "   iterations: " + nIter

if cMode = "free"
    for i = 1 to nIter
        st = ring_state_init()
        ring_state_runcode( st, 'x = 1' )
        ring_state_delete( st )
    next
else
    # exactly as published to the group in July 2024
    for i = 1 to nIter
        ring_state_runcode( ring_state_init(), 'x = 1' )
    next
ok

? "done"
