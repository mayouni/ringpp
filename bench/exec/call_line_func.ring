# A "Called from line N" frame reports where the CALL STARTS -- the callee's
# line -- not where the arguments end. Ring stamps the CALL instruction when
# it reads the function name; a plain function call whose arguments span
# three lines is attributed to the FIRST line. Six cluster tests differed
# only on this, through stzAppCluster.withfacet() -> stzraise(...): ours
# said 144, Ring said 142. Uncaught on purpose, so the trace prints.
zzGo()
func zzGo
    zzBoom("a" +
           "b" +
           "c")
func zzBoom p
    raise("from a three-line call")
