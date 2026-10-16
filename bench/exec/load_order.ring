# A loaded file's top level runs AT THE LOAD STATEMENT, not after the
# loader's own. Ring's rule, and the reason spliceOne exists: Softanza's
# stkRingLibs calls StzMetaInit() on a handle a LOADED file assigns, so
# running the blocks in queue order instead put the call before the
# assignment. Caught again on 2026-09-10, when the loader began resolving
# relative loads against the current directory (as Ring does) while the
# splice still resolved them against the loading file's -- the two
# disagreed, the target was not found, and the order silently inverted.
? "A before load"
load "load_order_dep.ring"
? "C after load, and the dep set $g to " + $g
